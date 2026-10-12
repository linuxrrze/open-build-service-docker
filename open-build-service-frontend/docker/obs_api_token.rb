#
# OBS API-token issuer.
#
# The API host (obs-api.example.com) is protected by traefik's `basicauth`
# middleware. Instead of every user hand-crafting a bcrypt hash, this small
# WEBrick service lets a logged-in OIDC user issue / revoke their OWN HTTP
# Basic password. The user's identity is taken from the `X-username` header
# that the web host's OIDC middleware injects; a user can only ever manage
# their OWN token.
#
# Trust: requests are accepted only if they carry the X-Obs-Issuer-Secret
# header matching OBS_API_TOKEN_ISSUER_SECRET. Only traefik's
# `obs-token-issuer` middleware adds it (after stripping client-supplied
# identity headers and running OIDC), so another container on the docker
# network can't call this service with a forged X-username.
#
# Routes:
#   GET  /_obs_api_token          small HTML page: status + issue/revoke buttons
#   GET  /_obs_api_token/status   JSON {user, token_exists}
#   POST /_obs_api_token          issue (or re-issue) the caller's token; the
#                                 plaintext is returned ONCE and never stored
#   POST /_obs_api_token/revoke   delete the caller's htpasswd entry
# POSTs also require the header `X-Requested-With: obs-api-token`: a
# cross-site page can't send a custom header without a CORS preflight, which
# this service never answers, so another site can't make a logged-in user's
# browser rotate or revoke their token (CSRF).
#
# State: only the token's bcrypt hash, in the htpasswd file that traefik's
# `basicauth.usersFile` watches and reloads (new users are valid at once).
#
# Run (the `frontend-token` compose service, as the frontend user):
#   bundle exec ruby /usr/local/bin/obs_api_token.rb
# `webrick` is a default gem in the image's Ruby 2.7; `bcrypt` comes from the
# baked Gemfile (it's an OBS dependency).
#
# Env:
#   OBS_API_TOKEN_ISSUER_SECRET  (required) shared secret with traefik
#   OBS_API_TOKEN_HTPASSWD       (default /etc/obs/obs-api-htpasswd)
#   OBS_API_TOKEN_PORT           (default 3001)
#
require 'webrick'
require 'json'
require 'securerandom'
require 'bcrypt'
require 'cgi'
require 'digest'

HTPASSWD = ENV.fetch('OBS_API_TOKEN_HTPASSWD', '/etc/obs/obs-api-htpasswd')
PORT     = ENV.fetch('OBS_API_TOKEN_PORT', '3001').to_i
SECRET   = ENV['OBS_API_TOKEN_ISSUER_SECRET'].to_s
PREFIX   = '/_obs_api_token'
CSRF_HEADER = 'obs-api-token'

abort 'OBS_API_TOKEN_ISSUER_SECRET must be set (at least 32 characters)' if SECRET.length < 32

# Constant-time string comparison (compare fixed-length digests byte by byte).
def secure_equal?(a, b)
  x = Digest::SHA256.digest(a.to_s).bytes
  y = Digest::SHA256.digest(b.to_s).bytes
  x.zip(y).reduce(0) { |acc, (i, j)| acc | (i ^ j) }.zero?
end

# All state logic in one small class; concurrent requests are serialized by
# @mutex.
class TokenIssuer
  def initialize(htpasswd:)
    @htpasswd = htpasswd
    @mutex    = Mutex.new
    # The htpasswd file must exist at boot so traefik's usersFile has
    # something to watch from the very first API request (an empty file
    # simply means "no users yet" and 401s everything).
    @mutex.synchronize do
      File.open(@htpasswd, 'a') { } unless File.exist?(@htpasswd)
    end
  end

  # Current htpasswd lines, as [user, hash] pairs (skip blanks/malformed).
  def read_htpasswd
    return [] unless File.exist?(@htpasswd)
    File.readlines(@htpasswd).map { |l| l.chomp.split(':', 2) }.reject { |u, _| u.to_s.empty? }
  end

  # Replace the whole htpasswd file atomically (temp file in the same
  # directory, then rename) so traefik's watcher never sees a half-written file.
  def write_htpasswd(pairs)
    data = pairs.map { |u, h| "#{u}:#{h}" }.join("\n")
    data += "\n" unless data.empty?
    tmp = File.join(File.dirname(@htpasswd),
                    ".#{File.basename(@htpasswd)}.tmp-#{$$}-#{SecureRandom.hex(4)}")
    File.write(tmp, data)
    File.rename(tmp, @htpasswd)
  rescue SystemCallError => e
    File.delete(tmp) if tmp && File.exist?(tmp)
    raise e
  end

  def token_exists?(user)
    read_htpasswd.any? { |u, _| u == user }
  end

  def issue_for(user)
    token = SecureRandom.hex(18)
    hash  = BCrypt::Password.create(token, cost: 10).to_s
    @mutex.synchronize do
      write_htpasswd(read_htpasswd.reject { |u, _| u == user } << [user, hash])
    end
    { user: user, token: token,
      note: 'shown only once -- store it now; it is the HTTP Basic password for the obs-api host' }
  end

  def revoke_for(user)
    @mutex.synchronize do
      write_htpasswd(read_htpasswd.reject { |u, _| u == user })
    end
    { user: user, revoked: true }
  end
end

def page(user, exists)
  u = CGI.escapeHTML(user)
  <<~HTML
    <!DOCTYPE html>
    <html><head><meta charset="utf-8"><title>OBS API token</title></head>
    <body style="font-family: sans-serif; max-width: 40em; margin: 2em auto">
    <h1>OBS API token for #{u}</h1>
    <p>Status: <b id="status">#{exists ? 'a token is set' : 'no token'}</b></p>
    <p>Use it as the HTTP Basic password for user <code>#{u}</code> on the API
    host (e.g. <code>osc -A https://obs-api.example.com ...</code>).
    Issuing a new token replaces the old one. The token is shown only once.</p>
    <button onclick="act('')">Issue new token</button>
    <button onclick="act('/revoke')">Revoke token</button>
    <pre id="out"></pre>
    <script>
    async function act(path) {
      const r = await fetch('#{PREFIX}' + path, {method: 'POST',
        headers: {'X-Requested-With': '#{CSRF_HEADER}'}});
      const j = await r.json();
      document.getElementById('out').textContent = JSON.stringify(j, null, 2);
      if (r.ok) document.getElementById('status').textContent = j.token ? 'a token is set' : 'no token';
    }
    </script>
    </body></html>
  HTML
end

class TokenHandler < WEBrick::HTTPServlet::AbstractServlet
  def initialize(server, issuer)
    super(server)
    @issuer = issuer
  end

  def do_GET(req, res)
    handle(req, res) do |user, sub|
      case sub
      when ''
        res['Content-Type'] = 'text/html; charset=utf-8'
        res.body = page(user, @issuer.token_exists?(user))
      when 'status'
        json(res, 200, user: user, token_exists: @issuer.token_exists?(user))
      else
        json(res, 405, error: 'use POST to issue or revoke a token')
      end
    end
  end

  def do_POST(req, res)
    handle(req, res) do |user, sub|
      if req['X-Requested-With'] != CSRF_HEADER
        json(res, 403, error: "missing header X-Requested-With: #{CSRF_HEADER}")
        next
      end
      case sub
      when ''       then json(res, 200, @issuer.issue_for(user))
      when 'revoke' then json(res, 200, @issuer.revoke_for(user))
      else json(res, 404, error: 'not found')
      end
    end
  end

  private

  def json(res, code, body)
    res.response_code   = code
    res['Content-Type'] = 'application/json'
    res.body = body.to_json
  end

  def handle(req, res)
    res['Cache-Control'] = 'no-store'
    # Only traefik knows the secret: fail closed for anything else.
    unless secure_equal?(req['X-Obs-Issuer-Secret'], SECRET)
      return json(res, 403, error: 'forbidden')
    end
    user = req['X-username'].to_s.strip
    if user.empty?
      return json(res, 401, error: 'unauthenticated (no X-username header; log in via the web host)')
    end
    # The name becomes an htpasswd line ("user:hash"): only allow characters
    # valid in OBS logins, never ':' or line breaks.
    unless user.match?(/\A[\w.@+-]+\z/)
      return json(res, 400, error: 'user name not usable for an API token')
    end
    sub = req.path.sub(%r{\A#{Regexp.escape(PREFIX)}/?}, '')
    yield user, sub
  rescue StandardError => e
    json(res, 500, error: "#{e.class}: #{e.message}")
  end
end

issuer = TokenIssuer.new(htpasswd: HTPASSWD)
server = WEBrick::HTTPServer.new(Port: PORT, LogFile: $stdout, AccessLog: [])
server.mount(PREFIX, TokenHandler, issuer)
trap('INT')  { server.shutdown }
trap('TERM') { server.shutdown }
puts "obs_api_token issuer listening on :#{PORT} (htpasswd=#{HTPASSWD})"
server.start
