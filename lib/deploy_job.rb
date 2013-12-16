require 'sucker_punch'
require_relative 'heroku_deployer'

class DeployJob
  include SuckerPunch::Job

  def perform(app_name, post_payload)
    HerokuDeployer.new(app_name, post_payload).deploy
  end
end
