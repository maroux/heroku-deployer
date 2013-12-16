require 'git-ssh-wrapper'
require 'git'
require 'zlib'
require 'ostruct'
require 'logger'

class HerokuDeployer
  attr_reader :app, :logger, :post_payload

  def self.exists?(app)
    !!(ENV["#{app}_HEROKU_REPO"] && ENV["#{app}_GIT_REPO"] && ENV["#{app}_SSH_KEY"])
  end

  def initialize(app_name, post_payload, logger = Logger.new(STDOUT))
    @app = app_name
    @post_payload = post_payload
    @logger = logger
  end

  def deploy
    tries = 0
    begin
      if post_payload['ref'] == "refs/heads/#{config.git_branch}"
          update_local_repository
          push
      end
    rescue
      tries += 1
      if tries <= 1
        `rm -r #{local_folder}` rescue nil
        retry
      end
    end
    logger.info 'done'
  end

  private

  def config
    @config ||= OpenStruct.new({
      heroku_repo: ENV["#{app}_HEROKU_REPO"],
      git_repo: ENV["#{app}_GIT_REPO"],
      ssh_key: ENV["#{app}_SSH_KEY"],
      git_branch: ENV["#{app}_GIT_BRANCH"] || "master",
    })
  end

  def local_folder
    @local_folder ||= "repos/#{Zlib.crc32(config.git_repo)}"
  end

  def repo_exists?
    Dir.exists?(File.join(local_folder, '.git'))
  end

  def update_local_repository
    GitSSHWrapper.with_wrapper(:private_key => config.ssh_key) do |wrapper|
      wrapper.set_env
      clone unless repo_exists?
      logger.info "fetching"
      logger.debug `cd #{local_folder} && git fetch && git reset --hard origin/#{config.git_branch}`
    end
  end

  def clone
    logger.info "cloning"
    logger.debug `git clone -b #{config.git_branch} #{config.git_repo} #{local_folder}`
    logger.debug `cd #{local_folder} && git remote add heroku #{config.heroku_repo}`
  end

  def push
    GitSSHWrapper.with_wrapper(:private_key => ENV['DEPLOY_SSH_KEY']) do |wrapper|
      wrapper.set_env
      logger.info "pushing"
      logger.debug `cd #{local_folder}; git push -f heroku #{config.git_branch}:master`
    end
  end
end
