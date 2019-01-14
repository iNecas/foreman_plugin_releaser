#!/usr/bin/env ruby

# TODO: extract to config file
# TODO: setup procedure
PACKAGING_PATH="/home/inecas/Projects/ws/foreman-rex/foreman-packaging/"

require 'optparse'
require 'rubygems'
require 'shellwords'

options = { dry: false, bump: 'z' }

COMMANDS = %w[gem redmine rpm deb]

if COMMANDS.include?(ARGV.first)
  options[:command] = ARGV.shift
end
OptionParser.new do |opts|
  opts.banner = "Usage: release.rb [#{COMMANDS.join("|")}] [options]"

  opts.on("-g", "--gemspec GEMSPEC", "Set GEMSPEC (optional)") do |gemspec|
    options[:gemspec] = gemspec
  end

  opts.on("-v", "--verbose", "Verbose output") do |verbose|
    options[:verbose] = verbose
  end

  opts.on("-d", "--dry", "Run in noop mode") do |dry|
    options[:dry] = dry
  end

  opts.on("-b", "--bump BUMP", "Bump x, y or z (#{options[:bump]} by default)") do |bump|
    options[:bump] = bump
  end


end.parse!

$dry = options[:dry]

def check_file_exists!(file)
  error("File #{file} does not exist") unless File.exist?(file)
end

def error(message)
  raise message
  #STDERR.puts(message)
  #Kernel.exit 1
end

def info(message)
  STDERR.puts(message)
end

# run non-modifying command
def run?(command)
  puts "> #{command}"
  system(command)
end

def run(command)
  `#{command}`
end

# run modifying command - wouldn't run in noop mode
def run!(command, term: false, term_message: "exit 0 to continue, exit 1 to cancel")
  puts "> #{command} (#{term ? term_message : ""}) #{$dry ? "(dry mode)" : ""}"
  unless $dry
    if term
      system(%{gnome-terminal --wait -- bash -c "#{command}; echo #{Shellwords.escape(term_message)}; exec $SHELL"})
    else
      system(command)
    end
    error "Command failed" unless $?.success?
  end
end

def ask?(question)
  puts "#{question} (y/N)"
  STDIN.gets.chomp == "y"
end

def ask_or_abort(question)
  unless ask?(question)
    error("Action aborted by user")
  end
end

module Release
  VERSION_REGEXP = /\d+.\d+.\d+/

  module Utils
    class << self
      def bump_version(version_file, regexp, replace_with)
        version_file_content = File.read(version_file)
        unless version_file_content.sub!(regexp, replace_with)
          error("No update when updating #{version_file} with #{regexp} and replace_with #{replace_with}")
        end
        if $dry
          puts "> would update #{version_file} (dry mode):"
          puts version_file_content
        else
          File.write(version_file, version_file_content)
        end
      end

      def find_file(path, allow_empty: false)
        candidates = Dir.glob(path)
        case candidates.size
        when 0
          if allow_empty
            return nil
          else
            error("No file matching file found at #{path}")
          end
        when 1
          candidates.first
        else
          error("Too many files matching #{path} files found: #{candidates}")
        end
      end

      def find_files(path, allow_empty: false)
        candidates = Dir.glob(path)
        case candidates.size
        when 0
          if allow_empty
            return []
          else
            error("No file matching file found at #{path}")
          end
        else
          candidates
        end
      end
    end
  end

  module RunInDir
    def run?(*args)
      in_dir { super(*args) }
    end

    def run!(*args)
      in_dir { super(*args) }
    end

    def run(*args)
      in_dir { super(*args) }
    end

    def in_dir(&block)
      Dir.chdir(@dir, &block)
    end
  end

  class OsPackage
    include RunInDir

    def initialize
      @dir = PACKAGING_PATH
      @git = Git.new(PACKAGING_PATH, base_branch)
      @gems = select_to_update(Utils.find_files("*gemspec").map { |gemspec| Gem.new(gemspec) })
      error("No gems need update") if @gems.empty?
    end

    def select_to_update(gems)
      gems.select do |gem|
        needs_update?(gem)
      end
    end

    def needs_update?(gem)
      current_version(gem) < gem.current_version
    end

    def prepare_git
      @git.ensure_clean!
      @git.checkout
      @git.pull
    end

    def base_branch
      "#{shortname}/develop"
    end

    def shortname
      self.class.name.split("::").last.downcase
    end

    def version_branch
      gem = @gems.sort_by(&:gemname).first
      "#{shortname}/#{gem.gemname}-#{gem.current_version}"
    end

    def current_version(gem)
      raise NotImplementedError
    end
  end

  class Rpm < OsPackage

    def release
      prepare_git
      @git.new_branch(version_branch)
      @gems.each do |gem|
        release_gem(gem)
      end
      @git.pull_request
    end

    def release_gem(gem)
      path = package_path(gem)
      run!("./bump_rpm.sh #{path}; cd #{path}", term: true, term_message: "Review the dependencies: git commit --amend on update; exit 0 to confirm, exit 1 to cancel")
    end

    def package_path(gem)
      in_dir do
        Utils.find_file("packages/*/rubygem-#{gem.gemname}")
      end
    end

    def spec_path(gem)
      in_dir do
        Utils.find_file("#{package_path(gem)}/*.spec") 
      end
    end

    def current_version(gem)
      version = run(%{rpmspec --srpm -q --queryformat='%{v}' #{spec_path(gem)}})
      ::Gem::Version.new(version)
    end
  end

  class Deb < OsPackage
    def release
      prepare_git
      in_dir do
        foreman_paths, proxy_paths = Hash.new { |h, k| h[k] = [] }, Hash.new { |h, k| h[k] = [] }

        @gems.each do |gem|
          paths = package_paths(gem)
          paths.each do |path|
            if path =~ /^dependencies/ || path.include?('smart_proxy')
              proxy_paths[gem] << path
            else
              foreman_paths[gem] << path
            end
          end
        end

        unless foreman_paths.empty?
          @git.new_branch(version_branch)
          foreman_paths.each do |gem, paths|
            paths.each { |path| release_at_path(gem, path) }
            @git.commit("Update #{gem.gemname} to #{gem.current_version}")
          end
          @git.pull_request
        end

        unless proxy_paths.empty?
          @git.checkout(base_branch)
          @git.new_branch("#{version_branch}-proxy")
          proxy_paths.each do |gem, paths|
            paths.each { |path| release_at_path(gem, path) }
            @git.commit("Update #{gem.gemname} to #{gem.current_version}")
          end
          @git.pull_request
        end
      end
    end

    def release_at_path(gem, path)
      in_dir do
        old_version = current_version_at_path(path)
        return false unless old_version < gem.current_version
        changelog = find_changelog(path)
        run!("scripts/changelog.rb -v #{gem.current_version} #{changelog}")

        if gemfile = Utils.find_file("#{path}/*.rb", allow_empty: true)
          Utils.bump_version(gemfile, /(#{gem.gemname}.*)#{VERSION_REGEXP}/, "\\1#{gem.current_version}")
        end

        if gemlist_file = Utils.find_file("#{path}/**/gem.list", allow_empty: true)
          gemlist = File.read(gemlist_file)
          @gems.each do |g|
            regexp = /(#{g.gemname}-)#{VERSION_REGEXP}/
            if gemlist =~ regexp
              Utils.bump_version(gemlist_file, regexp, "\\1#{g.current_version}")
            end
          end
        end
        @git.add(path)
        run!("cd #{path}; gem compare -b #{gem.gemname} #{old_version} #{gem.current_version}",
             term: true, term_message: "Review the dependencies: git add on update, exit 0 to confirm, exit 1 to cancel")
      end
    end

    def package_paths(gem)
      in_dir do
        candidates = []
        variants = [gem.gemname, gem.gemname.tr('_', '-')]
        variants.each do |variant| 
          candidates.concat(Utils.find_files("plugins/*#{variant}", allow_empty: true))
          candidates.concat(Utils.find_files("dependencies/*/#{variant}", allow_empty: true))
        end
        error("No DEB package candidates for #{gem.gemname} found") if candidates.empty?
        candidates
      end
    end

    def in_dir(&block)
      Dir.chdir(@dir, &block)
    end

    def current_version(gem)
      package_paths(gem).map do |path|
        current_version_at_path(path)
      end.min
    end

    def current_version_at_path(path)
      in_dir do
        changelog = find_changelog(path)
        version = File.read(changelog).lines.first[VERSION_REGEXP]
        error("Could not load version from changelog #{changelog}") unless version
        ::Gem::Version.new(version)
      end
    end

    def find_changelog(path)
      in_dir do
        Utils.find_file("#{path}/**/changelog")
      end
    end
  end

  class Gem
    include RunInDir

    class << self
      def find_gemspec
        specs = Dir.glob("*.gemspec")
        case specs.size
        when 0
          error("No gemspec file found")
        when 1
          return specs.first
        else
          error("More than one gemspecs found: #{specs}")
        end
      end
    end

    attr_reader :gemspec

    def initialize(gemspec)
      @gemspec = gemspec
      @dir = File.dirname(File.expand_path(@gemspec))
      @git = Git.new(File.dirname(gemspec), "master")
    end

    def check_exists!
      check_file_exists!(@gemspec)
    end

    def build
      out = `gem build #{@gemspec}`
    end

    def bump_version(bump = 'z')
      next_version = calculate_next_version(bump)
      info("Bumping version of #{gemname} to #{next_version}")
      @git.ensure_clean!
      @git.ensure_uptodate!
      @git.add(version_file)
      next_tag = "#{tag_prefix}#{next_version}"
      package_desc = core_package? ? ' core' : ''
      Utils.bump_version(version_file, VERSION_REGEXP, next_version.to_s)

      @git.add(version_file)
      @git.commit("Bump#{package_desc} version to #{next_version}")
      @git.tag(next_tag)
      @git.show('HEAD')
      ask_or_abort("Are you sure to push the following commit + tag #{next_tag} into origin?")
      @git.push('origin', 'HEAD')
      @git.push('origin', next_tag)
    end

    def push_gem
      run!(%{gem build #{gemspec}})
      gemfile = "#{gemname}-#{current_version}.gem"
      check_file_exists!(gemfile) unless $dry
      ask_or_abort("Push #{gemfile} to rubygems?")
      run!(%{gem push "#{gemfile}"})
    end

    def gemname
      @gemspec[0...-File.extname(@gemspec).size]
    end

    def current_version
      check_file_exists!(version_file)
      ::Gem::Version.new(File.read(version_file)[/VERSION.*(#{VERSION_REGEXP})/, 1])
    end

    private

    def core_package?
      gemname =~ /_core$/
    end

    def tag_prefix
      prefix = ""
      prefix << "core-" if core_package?
      prefix << "v"
      prefix
    end

    def calculate_next_version(bump)
      xyz = %w[x y z]
      error "Unknown part to bump: #{bump}. Expected one of x, y, z" unless xyz.include?(bump)
      segment_index = xyz.index(bump)
      segments = current_version.segments
      segments[segment_index] = segments[segment_index].succ
      (segment_index+1...segments.size).each { |i| segments[i] = 0 }
      segments.join('.')
    end

    def version_file
      version_file = "lib/#{gemname}/version.rb"
      File.expand_path(version_file, @dir)
    end
  end

  class Git
    include RunInDir

    def initialize(dir, branch)
      @dir = dir
      @branch = branch
    end

    def remote
      "origin"
    end

    def ensure_clean!
      unless run?("git diff --quiet && git diff --cached --quiet")
        error("Can't run on dirty workdir")
      end
    end

    def checkout(branch = @branch)
      run!(%{git checkout #{branch}})
    end

    def new_branch(branch)
      if branches.include?(branch)
        run!(%{git checkout "#{branch}"})
      else
        run!(%{git checkout -b "#{branch}"})
      end
    end

    def branches
      run('git branch').lines.map { |b| b[/\w\S+/] }
    end

    def pull
      run!(%{git pull #{remote}})
    end

    def ensure_uptodate!
      branch = `git rev-parse --abbrev-ref HEAD`.chomp
      unless branch == expected_branch
        error("current branch #{branch} doesn't equal expected branch #{expected_branch}")
      end

      run!(%{git fetch #{remote}})
      local_sha = `git rev-parse #{expected_branch}`.chomp
      remote_sha = `git rev-parse #{remote}/#{expected_branch}`.chomp
      unless local_sha == remote_sha
        error("local sha #{local_sha} (#{expected_branch}) doesn't equal remote sha #{remote_sha} (#{remote}/#{expected_branch})")
      end

    end

    def add(files)
      run!(%{git add "#{files}"})
    end

    def commit(message)
      run!(%{git commit -m "#{message}"})
    end

    def tag(tag)
      run!(%{git tag #{tag}})
    end

    def show(ref)
      run?(%{git show #{ref}})
    end

    def push(remote, ref)
      run!("git push #{remote} #{ref}")
    end

    def pull_request
      # TODO: make configurable
      run!("git push iNecas HEAD")
      run!("hub pull-request -b #{expected_branch}")
    end

    def expected_branch
      @branch
    end
  end
end


if __FILE__ == $PROGRAM_NAME
  begin
    case options[:command]
    when "gem"
      gem = Release::Gem.new(options[:gemspec] || Release::Gem.find_gemspec)
      gem.check_exists!
      gem.bump_version(options[:bump])
      gem.push_gem
    when "rpm"
      rpm = Release::Rpm.new
      rpm.release
    when "deb"
      deb = Release::Deb.new
      deb.release
    when "redmine"
      error "not implemented yet"
    else
      error "Unknown command '#{options[:command]}'. Possible commands are #{COMMANDS}"
    end
  rescue => e
    STDERR.puts(e.message)
    STDERR.puts(e.backtrace.join("\n")) if options[:verbose]
    exit 1
  end
end

# TODOs:
# - [ ] - bump rpm automatically
# - [ ] - bump deb automatically
# - [ ] - update redmine automatically (add version, assign fixed_in and target milestone)
# - [ ] - configure directories
