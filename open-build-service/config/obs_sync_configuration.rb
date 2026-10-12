# Sync .env settings into OBS's instance configuration and write it to the
# backend as /srv/obs/configuration.xml. CI adds this as
# src/api/script/obs_sync_configuration.rb; the frontend runs it on every
# start, after the migrations:
#   bin/rails runner script/obs_sync_configuration.rb
#
# Why: the backend reads its instance name (Origin/vendor, e.g.
# "obs://<name>/..."), the scheduler architectures, project-key enforcement
# etc. from configuration.xml, but OBS only writes that file when an admin
# saves the configuration page. A fresh backend data dir therefore has none,
# and the backend falls back to "build.some.where" and no schedulers list.
#
# The scheduler architectures are NOT taken from .env: they are OBS's own
# "Architecture Availability" (Admin > Architectures), stored in the database
# and written as <schedulers> unchanged; the backend's obs-sched-manager
# starts/stops schedulers to match.
#
# Settings (all optional, unset = keep what's in the database):
#   OBS_NAME                     -> <name>
#   OBS_URL                      -> <obs_url>
#   OBS_ADMIN_EMAIL              -> <admin_email>
#   OBS_SIGN / OBS_SIGN_FORCE_PROJECT_KEYS -> <enforce_project_keys>
#
# Upstream touch points (frontend CI drift guard): Architecture#available,
# Configuration#write_to_backend, the after_save :delayed_write_to_backend
# callback.

config = Configuration.first
abort 'obs_sync_configuration: no Configuration record (database not seeded?)' unless config

attrs = {}
{ 'OBS_NAME' => :name, 'OBS_URL' => :obs_url, 'OBS_ADMIN_EMAIL' => :admin_email }.each do |env, key|
  attrs[key] = ENV[env] if ENV[env].present?
end
if ENV.key?('OBS_SIGN') || ENV.key?('OBS_SIGN_FORCE_PROJECT_KEYS')
  attrs[:enforce_project_keys] = ENV.fetch('OBS_SIGN', '1') == '1' &&
                                 ENV.fetch('OBS_SIGN_FORCE_PROJECT_KEYS', '1') == '1'
end

# Write synchronously below instead of through the delayed job, so a failure
# is visible here.
Configuration.skip_callback(:save, :after, :delayed_write_to_backend)
config.update!(attrs) if attrs.any?

# The backend may still be starting up: retry for about a minute.
tries = 0
begin
  config.write_to_backend
rescue StandardError => e
  tries += 1
  raise if tries >= 12
  warn "obs_sync_configuration: backend not reachable yet (#{e.class}), retrying..."
  sleep 5
  retry
end
puts "obs_sync_configuration: wrote configuration.xml (name=#{config.name}, " \
     "schedulers=#{Architecture.available.pluck(:name).sort.join(' ')})"
