# Container-deployment settings for the baked OBS frontend. CI adds this as
# src/api/config/initializers/zz_container.rb -- a NEW file, so no upstream
# file is replaced; "zz_" makes it run after all upstream initializers.

# Puma is the web server in this stack (traefik only proxies and can't see the
# container's public/), so Rails must serve public/assets itself. Upstream's
# production.rb turns this off, expecting Apache/nginx in front. Set here, it
# still takes effect: the middleware stack is built after the initializers.
Rails.application.config.public_file_server.enabled = true

# options.yml is plain YAML (no ERB), but CONFIG is an ordinary Hash that OBS
# only reads at request time for these keys, so .env can override them here.
{
  'OBS_PROXY_AUTH_LOGIN_PAGE'    => 'proxy_auth_login_page',
  'OBS_PROXY_AUTH_LOGOUT_PAGE'   => 'proxy_auth_logout_page',
  'OBS_PROXY_AUTH_ACCOUNT_PAGE'  => 'proxy_auth_account_page',
  'OBS_PROXY_AUTH_REGISTER_PAGE' => 'proxy_auth_register_page'
}.each do |env, key|
  CONFIG[key] = ENV[env] if ENV[env].present?
end

# Session secret: Rails 5.2 already prefers ENV['SECRET_KEY_BASE'] in
# production. The image only ships a placeholder config/secret.key so that
# upstream's secret_token.rb (which raises without that file) is happy; make
# sure the placeholder can never end up being the real secret.
if Rails.env.production?
  raise 'SECRET_KEY_BASE env not set (required in production)' if ENV['SECRET_KEY_BASE'].blank?
  Rails.application.config.secret_key_base = ENV['SECRET_KEY_BASE']
end

# Architecture Availability is set by admins in the web UI (database ->
# configuration.xml -> backend schedulers). But upstream's clock job
# (WorkerStatus#update_workerstatus_cache, every 30 s) sets
# Architecture.available = true for every scheduler the backend reports --
# upstream's own "FIXME2.5 ... gross hack, not connected at all to the backend
# config" -- and the backend reports every bs_sched.<arch>.lock, including
# stopped schedulers. Disabled architectures therefore came back on their own.
# Keep upstream's queue statistics, drop the availability write-back. (The
# frontend CI drift guard checks upstream's method, see the workflow.)
module ObsKeepArchitectureAvailability
  private

  def parse_daemon_infos(daemon)
    return unless daemon['type'] == 'scheduler'
    arch = daemon['arch']
    queue = daemon.get('queue')
    return unless queue
    ['high', 'next', 'med', 'low'].each { |key| add_squeue("squeue_#{key}_#{arch}", queue[key]) }
  end
end
Rails.application.config.to_prepare { WorkerStatus.prepend(ObsKeepArchitectureAvailability) }

# Architecture Availability checkboxes (Admin > Architectures, webui2): each
# click PATCHes /architectures/:id, and the controller saves
# `available: params[:available] == 'true'`. But upstream's page disables the
# checkbox in its `ajax:before` handler, and jquery_ujs serializes the
# (now disabled, hence skipped) input only afterwards -- so the request never
# carries `available`, and every click, check or uncheck, saved `false`.
# One click is one request, so a missing value can only mean "flip it": use
# the parameter when present (e.g. once upstream fixes its page), otherwise
# toggle the stored value. (Frontend CI drift guard checks upstream's action.)
module ObsArchitectureToggleFix
  def update
    unless params.key?(:available)
      params[:available] = (!Architecture.find(params[:id]).available).to_s
    end
    super
  end
end
Rails.application.config.to_prepare { Webui::ArchitecturesController.prepend(ObsArchitectureToggleFix) }
