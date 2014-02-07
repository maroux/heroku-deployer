require 'git-ssh-wrapper'
require 'git'
require 'zlib'
require 'ostruct'
require 'logger'
require 'date'
require 'optparse'

class HerokuDeployer
  attr_reader :app, :logger, :post_payload

  def self.exists?(app)
    !!(ENV["#{app}_HEROKU_STAGE_REPO"] && ENV["#{app}_HEROKU_MASTER_REPO"] && ENV["#{app}_GIT_REPO"] && ENV["#{app}_SSH_KEY"])
  end

  def initialize(app_name, post_payload = nil, logger = Logger.new(STDOUT))
    @app = app_name
    @post_payload = post_payload
    @logger = logger
  end

  def deploy
    tries = 0
    begin
      # only merge next to staging during non-code freeze time 
      if post_payload['ref'] == "refs/heads/#{config.git_next_branch}" and
          (DateTime.now().new_offset('-0800').hour < 14 and 
          DateTime.now().new_offset('-0800').hour >= 0)
              update_staging_env
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

  def update_staging_env
      update_local_repository(config.git_next_branch)
      update_local_repository(config.git_staging_branch)
      merge
      push
  end

  def config
    @config ||= OpenStruct.new({
      heroku_stage_repo: ENV["#{app}_HEROKU_STAGE_REPO"],
      heroku_master_repo: ENV["#{app}_HEROKU_MASTER_REPO"],
      git_repo: ENV["#{app}_GIT_REPO"],
      ssh_key: ENV["#{app}_SSH_KEY"],
      git_next_branch: ENV["#{app}_git_next_branch"] || "next",
      git_staging_branch: ENV["#{app}_git_staging_branch"] || "staging",
      git_master_branch: ENV["#{app}_git_master_branch"] || "master",
    })
  end

  def local_folder
    @local_folder ||= "repos/#{Zlib.crc32(config.git_repo)}"
  end

  def repo_exists?
    Dir.exists?(File.join(local_folder, '.git'))
  end

  def update_local_repository(branch)
    GitSSHWrapper.with_wrapper(:private_key => config.ssh_key) do |wrapper|
      wrapper.set_env
      clone unless repo_exists?
      logger.info "fetching"
      logger.debug `cd #{local_folder} && git checkout #{branch} && git fetch && git reset --hard origin/#{branch}`
    end
  end

  def merge
      GitSSHWrapper.with_wrapper(:private_key => config.ssh_key) do |wrapper|
          wrapper.set_env
          logger.debug `cd #{local_folder} && git merge #{config.git_next_branch} -m "Auto-merging #{config.git_next_branch} to #{config.git_staging_branch}"` 
      end
  end

  def clone
    logger.info "cloning"
    logger.debug `git clone #{config.git_repo} #{local_folder}`
    logger.debug `cd #{local_folder} && git remote add heroku-stage #{config.heroku_stage_repo} && git remote add heroku-master #{config.heroku_master_repo}`
  end

  def push
    GitSSHWrapper.with_wrapper(:private_key => config.ssh_key) do |wrapper|
      wrapper.set_env
      logger.info "pushing to github"
      logger.debug `cd #{local_folder}; git push origin #{config.git_staging_branch}`
    end
    GitSSHWrapper.with_wrapper(:private_key => ENV['DEPLOY_SSH_KEY']) do |wrapper|
      wrapper.set_env
      logger.info "pushing to heroku"
      logger.debug `cd #{local_folder}; git push -f heroku-stage #{config.git_staging_branch}:master`
    end
  end

  def get_commit_to_merge
      GitSSHWrapper.with_wrapper(:private_key => config.ssh_key) do |wrapper|
          wrapper.set_env
          clone unless repo_exists?
          logger.info 'Fetching commit to merge'
          # update both branches
          update_local_repository(config.git_next_branch)
          update_local_repository(config.git_staging_branch)
          before_date = DateTime.new(year=DateTime.now.year, 
                                     month=DateTime.now.month, 
                                     day=DateTime.now.day, 
                                     hour=14, 
                                     minute=0, 
                                     second=0, 
                                     '-8')
          after_date = DateTime.rfc2822(`cd #{local_folder} && git log -n1 --pretty="%cD" #{config.git_staging_branch}`).new_offset("-0800")
          before_date_str = before_date.strftime('%m-%d-%Y %H:%M:%S %z') 
          after_date_str = after_date.strftime('%m-%d-%Y %H:%M:%S %z')
          logger.info "Looking for commit after #{after_date_str} and before #{before_date_str}"
          commit_hash = `cd #{local_folder} && git log -n1 --after="#{after_date_str}" --before="#{before_date_str}" --pretty="%H #{config.git_next_branch}"`
          return commit_hash
      end
  end

  public 

  def merge_to_master(dry_run='')
      update_local_repository(config.git_staging_branch)
      update_local_repository(config.git_master_branch)
      GitSSHWrapper.with_wrapper(:private_key => config.ssh_key) do |wrapper|
        wrapper.set_env
        logger.debug `cd #{local_folder} && git merge #{config.git_staging_branch} -m "Auto-merging #{config.git_staging_branch} to #{config.git_master_branch}"`
        logger.debug `cd #{local_folder} && git push #{dry_run} origin #{config.git_master_branch}`
      end
      GitSSHWrapper.with_wrapper(:private_key => ENV['DEPLOY_SSH_KEY']) do |wrapper|
        wrapper.set_env
        logger.debug `cd #{local_folder} && git push #{dry_run} -f heroku_master #{config.git_master_branch}:master`
      end
      update_staging_env 
  end 
end

if __FILE__ == $0
    options = {}
    opt_parser = OptionParser.new do |opt|
        opt.banner = "Usage: opt_parser COMMAND [OPTIONS]"
        opt.separator  ""
        opt.separator  "Commands"
        opt.separator  "     merge_to_master"
        opt.separator  ""
        opt.separator  "Options"

        opt.on("-d","--dry-run","dry run - will not execute push") do
            options[:dry_run] = "--dry-run" 
        end

        opt.on("-h","--help","help") do
            puts opt_parser
        end
    end

    opt_parser.parse!

    case ARGV[0]
    when "merge_to_master"
        if not HerokuDeployer.exists?("server_heroku")
            print "no app found\n"
            exit 0 
        end
        HerokuDeployer.new("server_heroku").merge_to_master(options[:dry_run] || '')
    when "update_staging_env"
        if not HerokuDeployer.exists?("server_heroku")
            print "no app found\n"
            exit 0 
        end
        HerokuDeployer.new("server_heroku", {"ref" => "refs/heads/next"}).deploy
    else
        puts opt_parser
    end
end
