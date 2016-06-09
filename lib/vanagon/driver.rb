require 'vanagon/project'
require 'vanagon/platform'
require 'vanagon/component'
require 'vanagon/utilities'
require 'vanagon/common'
require 'vanagon/errors'
require 'tmpdir'
require 'logger'

class Vanagon
  class Driver
    include Vanagon::Utilities
    attr_accessor :platform, :project, :target, :workdir, :verbose, :preserve
    attr_accessor :timeout, :retry_count

    def initialize(platform, project, options = { :configdir => nil, :target => nil, :engine => nil, :components => nil, :skipcheck => false, :verbose => false, :preserve => false })
      @verbose = options[:verbose]
      @preserve = options[:preserve]

      @@configdir = options[:configdir] || File.join(Dir.pwd, "configs")
      components = options[:components] || []
      target = options[:target]
      engine = options[:engine] || 'pooler'

      @platform = Vanagon::Platform.load_platform(platform, File.join(@@configdir, "platforms"))
      @project = Vanagon::Project.load_project(project, File.join(@@configdir, "projects"), @platform, components)
      @project.settings[:verbose] = options[:verbose]
      @project.settings[:skipcheck] = options[:skipcheck]
      loginit('vanagon_hosts.log')

      load_engine(engine, @platform, target)
    rescue LoadError => e
      raise Vanagon::Error.wrap(e, "Could not load the desired engine '#{engine}'")
    end

    def load_engine(engine_type, platform, target)
      if platform.build_hosts
        engine_type = 'hardware'
      elsif platform.aws_ami
        engine_type = 'ec2'
      elsif platform.docker_image
        engine_type = 'docker'
      elsif target
        engine_type = 'base'
      end
      load_engine_object(engine_type, platform, target)
    end

    def load_engine_object(engine_type, platform, target)
      require "vanagon/engine/#{engine_type}"
      @engine = Object::const_get("Vanagon::Engine::#{engine_type.capitalize}").new(platform, target)
    rescue
      fail "No such engine '#{engine_type.capitalize}'"
    end

    def cleanup_workdir
      FileUtils.rm_rf(@workdir)
    end

    def self.configdir
      @@configdir
    end

    def self.logger
      @@logger
    end

    def build_host_info
      { "name" => @engine.build_host_name, "engine" => @engine.name }
    end

    # Returns the set difference between the build_requires and the components to get a list of external dependencies that need to be installed.
    def list_build_dependencies
      @project.components.map(&:build_requires).flatten.uniq - @project.components.map(&:name)
    end

    def install_build_dependencies
      unless list_build_dependencies.empty?
        if @platform.build_dependencies && @platform.build_dependencies.command && !@platform.build_dependencies.command.empty?
          @engine.dispatch("#{@platform.build_dependencies.command} #{list_build_dependencies.join(' ')} #{@platform.build_dependencies.suffix}")
        elsif @platform.respond_to?(:install_build_dependencies)
          @engine.dispatch(@platform.install_build_dependencies(list_build_dependencies))
        else
          raise Vanagon::Error, "No method defined to install build dependencies for #{@platform.name}"
        end
      end
    end

    def run
      # Simple sanity check for the project
      if @project.version.nil? or @project.version.empty?
        raise Vanagon::Error, "Project requires a version set, all is lost."
      end
      @workdir = Dir.mktmpdir
      @engine.startup(@workdir)

      puts "Target is #{@engine.target}"
      retry_task { install_build_dependencies }
      @project.fetch_sources(@workdir)
      @project.make_makefile(@workdir)
      @project.make_bill_of_materials(@workdir)
      @project.generate_packaging_artifacts(@workdir)
      @engine.ship_workdir(@workdir)
      retry_task { @engine.dispatch("(cd #{@engine.remote_workdir}; #{@platform.make})") }
      @engine.retrieve_built_artifact
      @engine.teardown unless @preserve
      cleanup_workdir unless @preserve
    rescue => e
      puts e
      puts e.backtrace.join("\n")
      raise e
    ensure
      if ["hardware", "ec2"].include?(@engine.name)
        @engine.teardown
      end
    end

    def prepare(workdir = nil)
      @workdir = workdir ? FileUtils.mkdir_p(workdir).first : Dir.mktmpdir
      @engine.startup(@workdir)

      puts "Devkit on #{@engine.target}"

      install_build_dependencies
      @project.fetch_sources(@workdir)
      @project.make_makefile(@workdir)
      @project.make_bill_of_materials(@workdir)
      # Builds only the project, skipping packaging into an artifact.
      @engine.ship_workdir(@workdir)
      @engine.dispatch("(cd #{@engine.remote_workdir}; #{@platform.make} #{@project.name}-project)")
    rescue => e
      puts e
      puts e.backtrace.join("\n")
      raise e
    end

    # Retry the provided block, use the retry count and timeout
    # values from the project, if available, otherwise use some
    # sane defaults.
    def retry_task(&block)
      @timeout = @project.timeout || ENV["TIMEOUT"] || 7200
      @retry_count = @project.retry_count || ENV["RETRY_COUNT"] || 1
      Vanagon::Utilities.retry_with_timeout(@retry_count, @timeout) { yield }
    end
    private :retry_task

    # Initialize the logging instance
    def loginit(logfile)
      @@logger = Logger.new(logfile)
      @@logger.progname = 'vanagon'
    end
    private :loginit
  end
end
