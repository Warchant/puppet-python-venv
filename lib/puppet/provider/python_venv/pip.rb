# frozen_string_literal: true

require 'json'
require 'tempfile'
require 'digest'
require 'set'

Puppet::Type.type(:python_venv).provide(:pip) do
  desc 'Manages Python virtual environments using python3 -m venv and pip.'

  commands python3: 'python3'

  def self.default_python_cmd
    command(:python3)
  rescue Puppet::MissingCommand
    'python3'
  end

  def python_cmd
    resource[:python_executable] || self.class.default_python_cmd
  end

  def venv_path
    resource[:path]
  end

  def pip_path
    File.join(venv_path, 'bin', 'pip')
  end

  def python_venv_path
    File.join(venv_path, 'bin', 'python')
  end

  def activate_path
    File.join(venv_path, 'bin', 'activate')
  end

  # Check if venv files are valid (not zero-sized)
  # Sometimes python3 -m venv exits with code 0 but creates invalid venv with zero-sized files
  def venv_files_valid?
    return false unless File.exist?(python_venv_path) && File.exist?(activate_path)

    python_size = File.size(python_venv_path)
    activate_size = File.size(activate_path)

    if python_size == 0 || activate_size == 0
      Puppet.warning("Invalid venv detected at #{venv_path}: python size=#{python_size}, activate size=#{activate_size}")
      return false
    end

    true
  end

  def exists?
    File.directory?(venv_path) && File.executable?(python_venv_path) && File.executable?(pip_path) && venv_files_valid?
  end

  def create
    create_venv
    sync_requirements if requirements?
  end

  def destroy
    Puppet::FileSystem.rmtree(venv_path) if File.exist?(venv_path)
  end

  # Check if requirements are in sync (called by the property)
  def requirements_in_sync?
    return true unless exists? && requirements?

    expected_state = calculate_expected_state
    actual_state = load_requirements_state

    # If state file is missing, we're out of sync
    return false unless File.exist?(requirements_state_file)

    # Check if expected state matches actual state (excluding pip_freeze_hash for now)
    expected_state.each do |key, value|
      return false if actual_state[key] != value
    end

    # Check pip freeze hash if it exists
    if actual_state['pip_freeze_hash']
      current_freeze_hash = get_pip_freeze_hash
      return false if current_freeze_hash && actual_state['pip_freeze_hash'] != current_freeze_hash
    end

    true
  end

  # Called on every Puppet run to ensure requirements are in sync
  def flush
    sync_requirements if exists? && requirements?
  end

  # Path to store requirements state
  def requirements_state_file
    File.join(venv_path, '.requirements_state')
  end

  # Path to store individual requirements as a file
  def individual_requirements_file
    File.join(venv_path, '.individual_requirements.txt')
  end

  # Load the current state of installed requirements
  def load_requirements_state
    return {} unless File.exist?(requirements_state_file)

    begin
      state = JSON.parse(File.read(requirements_state_file))
      Puppet.debug("Loaded requirements state: #{state.inspect}")
      state
    rescue JSON::ParserError => e
      Puppet.warning("Failed to parse requirements state file: #{e.message}")
      {}
    end
  end

  # Save the current state of installed requirements
  def save_requirements_state(state)
    File.write(requirements_state_file, JSON.pretty_generate(state))
    Puppet.debug("Saved requirements state: #{state.inspect}")
  end

  # Get hash of currently installed packages via pip freeze
  def get_pip_freeze_hash
    return nil unless exists?

    begin
      # use only `locally installed` deps in `venv` for pip freeze
      output = execute([pip_path, 'freeze', '-l'], failonfail: true)
      hash = Digest::SHA256.hexdigest(output)
      Puppet.debug("Pip freeze hash: #{hash[0..7]}...")
      hash
    rescue Puppet::ExecutionFailure => e
      Puppet.warning("Failed to run pip freeze: #{e.message}")
      nil
    end
  end

  # Calculate hash of a file
  def file_hash(file_path)
    Digest::SHA256.hexdigest(File.read(file_path))
  end

  # Parse requirements from a requirements.txt file, ignoring comments and empty lines
  def parse_requirements_file(file_path)
    File.readlines(file_path).map { |line|
      # Remove inline comments
      line = line.split('#').first || ''
      # Strip whitespace
      line = line.strip
      # Return nil for empty lines
      line.empty? ? nil : line
    }.compact.sort
  rescue StandardError => e
    Puppet.warning("Failed to parse requirements file #{file_path}: #{e.message}")
    []
  end

  # Calculate hash of individual requirements
  def individual_requirements_hash
    content = resource[:requirements].sort.join("\n")
    Digest::SHA256.hexdigest(content)
  end

  # Calculate expected requirements state (what should be installed)
  def calculate_expected_state
    state = {}

    # Track requirements files with their hashes and parsed contents
    resource[:requirements_files].each do |req_file|
      raise Puppet::Error, "Requirements file does not exist: #{req_file}" unless File.exist?(req_file)
      state["file:#{req_file}"] = file_hash(req_file)
      state["file_list:#{req_file}"] = parse_requirements_file(req_file)
    end

    # Track individual requirements with their hash and actual list
    unless resource[:requirements].empty?
      state['individual_requirements'] = individual_requirements_hash
      state['individual_requirements_list'] = resource[:requirements].sort
    end

    Puppet.debug("Calculated expected state: #{state.inspect}")
    state
  end

  private

  def create_venv
    cmd = [python_cmd, '-m', 'venv']
    cmd << '--system-site-packages' if resource[:system_site_packages]
    cmd << venv_path

    Puppet.info("Creating Python virtual environment at #{venv_path}")

    begin
      execute(cmd, failonfail: true, combine: true)
    rescue Puppet::ExecutionFailure => e
      raise Puppet::Error, "Failed to create virtual environment at #{venv_path}: #{e.message}"
    end

    # Verify venv was created successfully
    unless File.directory?(venv_path) && File.executable?(python_venv_path) && File.executable?(pip_path)
      raise Puppet::Error, "Virtual environment creation appeared to succeed but #{venv_path} is not functional"
    end

    # Check for invalid venv with zero-sized files
    unless venv_files_valid?
      Puppet.err("Python venv creation failed: #{venv_path} contains invalid zero-sized files")
      # Cleanup the invalid venv
      Puppet::FileSystem.rmtree(venv_path) if File.exist?(venv_path)
      raise Puppet::Error, "Failed to create valid virtual environment at #{venv_path}: venv files are zero-sized (corrupted creation)"
    end

    # Upgrade pip to ensure we have latest features
    upgrade_pip
  end

  def upgrade_pip
    Puppet.debug("Upgrading pip in #{venv_path}")
    begin
      execute([pip_path, 'install', '--upgrade', 'pip'], failonfail: false, combine: true)
    rescue Puppet::ExecutionFailure => e
      Puppet.warning("Failed to upgrade pip in #{venv_path}: #{e.message}")
    end
  end

  def requirements?
    !resource[:requirements].empty? || !resource[:requirements_files].empty?
  end

  # Sync requirements: compare expected vs actual and install what changed
  def sync_requirements
    return unless requirements?

    expected_state = calculate_expected_state
    actual_state = load_requirements_state

    Puppet.debug("Expected state: #{expected_state.inspect}")
    Puppet.debug("Actual state: #{actual_state.inspect}")

    # Determine if we need to reinstall
    requirements_changed = states_differ?(expected_state, actual_state)

    # Nothing to do if everything is in sync
    unless requirements_changed
      Puppet.info("Python venv #{venv_path}: No changes detected - requirements are in sync")
      return
    end

    # Log what changed
    log_changes(expected_state, actual_state)

    # Install all requirements
    install_all_requirements

    # Save new state
    save_state_after_install(expected_state)

    Puppet.info("Python venv #{venv_path}: Requirements synchronized successfully")
  end

  # Check if states differ
  def states_differ?(expected_state, actual_state)
    # Check requirements hashes
    expected_state.each do |key, value|
      return true if actual_state[key] != value
    end

    # Check pip freeze hash if it exists
    if actual_state['pip_freeze_hash']
      current_freeze_hash = get_pip_freeze_hash
      return true if current_freeze_hash && actual_state['pip_freeze_hash'] != current_freeze_hash
    end

    false
  end

  # Log what changed
  def log_changes(expected_state, actual_state)
    state_file_missing = !File.exist?(requirements_state_file)

    if state_file_missing
      Puppet.info("Python venv #{venv_path}: Installing requirements (initial setup)")
      return
    end

    Puppet.info("Python venv #{venv_path}: Changes detected - reinstalling requirements")

    # Track which files we've already logged in detail
    logged_files = Set.new

    # Log specific changes
    expected_state.each do |key, expected_value|
      actual_value = actual_state[key]
      next if expected_value == actual_value

      if key.start_with?('file:') && !key.start_with?('file_list:')
        file_path = key.sub('file:', '')
        # Check if we have detailed list to compare
        file_list_key = "file_list:#{file_path}"
        if expected_state[file_list_key] && actual_state[file_list_key]
          log_requirements_file_changes(file_path, expected_state[file_list_key], actual_state[file_list_key])
          logged_files.add(file_path)
        else
          Puppet.info("  - Requirements file changed: #{file_path}")
        end
      elsif key == 'individual_requirements'
        log_individual_requirements_changes(expected_state, actual_state)
      end
    end

    # Check pip freeze hash
    return unless actual_state['pip_freeze_hash']
    current_freeze_hash = get_pip_freeze_hash
    return unless current_freeze_hash && actual_state['pip_freeze_hash'] != current_freeze_hash
    Puppet.info('  - Installed packages modified externally')
  end

  # Log detailed changes in individual requirements
  def log_individual_requirements_changes(expected_state, actual_state)
    expected_list = expected_state['individual_requirements_list'] || []
    actual_list = actual_state['individual_requirements_list'] || []
    log_requirement_list_changes('Individual requirements', expected_list, actual_list)
  end

  # Log detailed changes in a requirements file
  def log_requirements_file_changes(file_path, expected_list, actual_list)
    log_requirement_list_changes("Requirements file: #{file_path}", expected_list, actual_list)
  end

  # Common method to log changes between two requirement lists
  def log_requirement_list_changes(label, expected_list, actual_list)
    # Convert to sets for comparison
    expected_set = Set.new(expected_list)
    actual_set = Set.new(actual_list)

    added = expected_set - actual_set
    removed = actual_set - expected_set

    # Detect version changes (same package, different version)
    changed = []
    added.each do |new_req|
      new_pkg = parse_package_name(new_req)
      removed.each do |old_req|
        old_pkg = parse_package_name(old_req)
        if old_pkg == new_pkg
          changed << [old_req, new_req]
          break
        end
      end
    end

    # Remove changed items from added/removed sets
    changed.each do |old_req, new_req|
      added.delete(new_req)
      removed.delete(old_req)
    end

    Puppet.info("  - #{label} changed:")

    # Log additions
    added.each do |req|
      Puppet.info("      + #{req}")
    end

    # Log removals
    removed.each do |req|
      Puppet.info("      - #{req}")
    end

    # Log changes
    changed.each do |old_req, new_req|
      Puppet.info("      ~ #{old_req} => #{new_req}")
    end
  end

  # Parse package name from requirement string (e.g., "httpx==1.0.0" => "httpx")
  def parse_package_name(requirement)
    # Handle common requirement specifiers: ==, >=, <=, >, <, !=, ~=
    requirement.split(%r{[=<>!~]+}).first.strip.downcase
  end

  # Install all requirements
  def install_all_requirements
    files_to_install = []

    # Collect requirements files
    resource[:requirements_files].each do |req_file|
      files_to_install << req_file
    end

    # Handle individual requirements
    unless resource[:requirements].empty?
      File.write(individual_requirements_file, resource[:requirements].join("\n") + "\n")
      files_to_install << individual_requirements_file
    end

    # Install each file with --force-reinstall (always force during sync to ensure consistency)
    files_to_install.each do |req_file|
      install_requirements_file(req_file)
    end
  end

  # Save state after successful installation
  def save_state_after_install(expected_state)
    new_state = expected_state.dup

    # Add pip freeze hash
    freeze_hash = get_pip_freeze_hash
    if freeze_hash
      new_state['pip_freeze_hash'] = freeze_hash
      Puppet.debug("Saved pip freeze hash: #{freeze_hash[0..7]}...")
    end

    save_requirements_state(new_state)
  end

  def install_requirements_file(requirements_file)
    cmd = [pip_path, 'install']
    cmd << '-r' << requirements_file
    cmd += resource[:pip_args]

    Puppet.info("Executing pip install: #{cmd.join(' ')}")

    begin
      output = execute(cmd, failonfail: true, combine: true)
      Puppet.info("Pip install completed successfully for #{requirements_file}")
      Puppet.debug("Pip install output: #{output}")
    rescue Puppet::ExecutionFailure => e
      raise Puppet::Error, "Failed to install requirements from #{requirements_file} in #{venv_path}: #{e.message}"
    end
  end
end
