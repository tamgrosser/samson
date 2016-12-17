# frozen_string_literal: true
require 'shellwords'

class JobExecution
  include ::NewRelic::Agent::Instrumentation::ControllerInstrumentation

  # Whether or not execution is enabled. This allows completely disabling job
  # execution for testing purposes and when restarting samson.
  cattr_accessor(:enabled, instance_writer: false) do
    Rails.application.config.samson.enable_job_execution
  end

  cattr_accessor(:lock_timeout, instance_writer: false) { 10.minutes }
  cattr_accessor(:stop_timeout, instance_writer: false) { 15.seconds }

  attr_reader :output, :reference, :job, :viewers, :executor

  delegate :id, to: :job
  delegate :pid, :pgid, to: :executor

  def initialize(reference, job, env = {}, &block)
    @output = OutputBuffer.new
    @executor = TerminalExecutor.new(@output, verbose: true, deploy: job.deploy)
    @viewers = JobViewers.new(@output)

    @subscribers = []
    @env = env
    @job = job
    @reference = reference
    @execution_block = block
    @stopped = false
    @finished = false
    @thread = nil

    @repository = @job.project.repository
    @repository.executor = @executor

    on_complete do
      @output.write('', :finished)
      @output.close

      @job.update_output!(OutputAggregator.new(@output).to_s)
    end
  end

  def start!
    ActiveRecord::Base.clear_active_connections!
    @thread = Thread.new { run! }
  end

  def wait!
    @thread.join
  end

  # Used on queued jobs when shutting down
  # so that the stream sockets are closed
  def close
    @output.write('', :reloaded)
    @output.close
  end

  def stop!
    return unless @thread&.alive?

    @stopped = true
    @executor.stop! 'INT'
    unless @thread.join(stop_timeout)
      @executor.stop! 'KILL'
      @thread.join(stop_timeout) || @thread.kill
    end

    @job.cancelled!
    finish
  end

  def on_complete(&block)
    @subscribers << JobExecutionSubscriber.new(job, block)
  end

  def descriptor
    "#{job.project.name} - #{reference}"
  end

  private

  def stage
    @job.deploy.try(:stage)
  end

  def error!(exception)
    puts_if_present report_to_airbrake(exception)
    puts_if_present "JobExecution failed: #{exception.message}"
    puts_if_present render_backtrace(exception)
    @job.error! if @job.active?
  end

  def run!
    @output.write('', :started)

    @job.run!

    success = make_temp_directory do |dir|
      return @job.error! unless setup!(dir)

      if @execution_block
        @execution_block.call(self, dir)
      else
        execute!(dir)
      end
    end

    if success
      @job.success!
    else
      @job.fail!
    end
  rescue => e
    error!(e) unless @stopped
  ensure
    finish unless @stopped # when thread was killed we might be in a bad state, so avoid doing work here
    ActiveRecord::Base.clear_active_connections!
  end
  add_transaction_tracer :run!,
    category: :task,
    params: '{ job_id: id, project: job.project.try(:name), reference: reference }'

  def finish
    return if @finished
    @finished = true
    @subscribers.each(&:call)
  end

  def execute!(dir)
    Samson::Hooks.fire(:after_deploy_setup, dir, @job, @output, @reference)

    FileUtils.mkdir_p(artifact_cache_dir)
    @output.write("\n# Executing deploy\n")
    @output.write("# Deploy URL: #{@job.deploy.url}\n") if @job.deploy

    cmds = commands(dir)
    payload = {
      stage: (stage.try(:name) || "none"),
      project: @job.project.name,
      command: cmds.join("\n")
    }

    ActiveRecord::Base.clear_active_connections!

    ActiveSupport::Notifications.instrument("execute_shell.samson", payload) do
      payload[:success] =
        if stage.try(:kubernetes)
          @executor = Kubernetes::DeployExecutor.new(@output, job: @job, reference: @reference)
          @executor.execute!
        else
          @executor.execute!(*cmds)
        end
    end

    Samson::Hooks.fire(:after_job_execution, @job, payload[:success], @output)

    payload[:success]
  end

  def setup!(dir)
    return unless resolve_ref_to_commit
    stage.try(:kubernetes) || checkout_workspace(dir)
  end

  def checkout_workspace(dir)
    locked = lock_repository do
      return false unless @repository.checkout_workspace(dir, @reference)
    end

    if locked
      true
    else
      @output.puts("Could not get exclusive lock on repo.")
      false
    end
  end

  def resolve_ref_to_commit
    @repository.update_local_cache!
    commit = @repository.commit_from_ref(@reference)
    tag = @repository.tag_from_ref(@reference)
    if commit
      @job.update_git_references!(commit: commit, tag: tag)
      @output.puts("Commit: #{commit}")
      true
    else
      @output.puts("Could not find commit for #{@reference}")
      false
    end
  end

  def commands(dir)
    env = {
      DEPLOY_URL: @job.url,
      DEPLOYER: @job.user.email,
      DEPLOYER_EMAIL: @job.user.email,
      DEPLOYER_NAME: @job.user.name,
      PROJECT_NAME: @job.project.name,
      PROJECT_PERMALINK: @job.project.permalink,
      PROJECT_REPOSITORY: @job.project.repository_url,
      REFERENCE: @reference,
      REVISION: @job.commit,
      TAG: (@job.tag || @job.commit),
      CACHE_DIR: artifact_cache_dir
    }.merge(@env)

    env.merge!(Hash[*Samson::Hooks.fire(:job_additional_vars, @job)])

    commands = env.map do |key, value|
      "export #{key}=#{value.shellescape}"
    end

    commands << "cd #{dir}"
    commands.concat(@job.commands)
    commands
  end

  def artifact_cache_dir
    File.join(@repository.repo_cache_dir, "artifacts")
  end

  def lock_repository(&block)
    holder = (stage.try(:name) || @job.user.name)
    @job.project.repository.exclusive(output: @output, holder: holder, timeout: lock_timeout, &block)
  end

  # show full errors if we show exceptions
  def render_backtrace(exception)
    return unless Rails.application.config.consider_all_requests_local
    backtrace = Rails.backtrace_cleaner.filter(exception.backtrace).first(10)
    backtrace << '...'
    backtrace.join("\n")
  end

  def report_to_airbrake(exception)
    return if exception.is_a?(Samson::Hooks::UserError) # do not spam us with users issues

    return unless error_id = Airbrake.notify(
      exception,
      error_message: exception.message,
      parameters: {job_id: @job.id}
    )

    raise 'unable to find url' unless url = Airbrake.configuration.user_information[/['"](http.*?)['"]/, 1]
    raise 'unable to find error' unless url.sub!('{{error_id}}', error_id)
    "Error #{url}"
  end

  def puts_if_present(message)
    @output.puts message if message
  end

  def make_temp_directory
    Dir.mktmpdir("samson-#{@job.project.permalink}-#{@job.id}") do |dir|
      begin
        yield dir
      ensure
        # make the mktmpdir ensure not blow up if the directory was removed
        Dir.mkdir(dir) unless Dir.exist?(dir)
      end
    end
  end

  class << self
    def find_by_id(id)
      job_queue.find_by_id(id)
    end

    def active?(id)
      job_queue.active?(id)
    end

    def queued?(id)
      job_queue.queued?(id)
    end

    def start_job(*args)
      job_queue.add(*args)
    end

    def active
      job_queue.active
    end

    def clear_queue
      job_queue.clear
    end

    def debug
      job_queue.debug
    end

    private

    def job_queue
      @job_queue ||= JobQueue.new
    end
  end
end
