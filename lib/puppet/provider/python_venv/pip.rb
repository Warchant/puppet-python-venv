# frozen_string_literal: true

require 'json'
require 'digest'
require 'set'
require 'fileutils'
require 'securerandom'

Puppet::Type.type(:python_venv).provide(:pip) do
  desc <<-DESC
    Manages Python virtual environments using python3 -m venv and pip.

    Correctness model:
    * The venv is "done" only when the commit marker (.requirements_state) exists,
      matches the declared inputs, and verification passes.
    * Any change or failed check builds a new venv from scratch: requirements are
      installed, data is flushed to disk, every installed file is verified against its
      RECORD sha256, and only then the marker is written atomically.
    * atomic => false (default): the venv is deleted (marker first) and built in place.
    * atomic => true: the path is a symlink to a build in .<name>.builds/; the new venv
      is built there and the symlink is switched with one rename once it is committed.
      Applications see the old venv or the new one, never a partial one; a failed build
      leaves the old venv in place.
    * Every check fails closed: an error while checking is treated as "out of sync".
  DESC

  commands python3: 'python3'

  const_set(:STATE_FORMAT, 2)
  const_set(:LEGACY_STATE, :legacy_state)

  # Verifies every installed distribution in the venv against its dist-info/RECORD.
  # Runs with the venv interpreter in isolated mode; stdlib only, Python 3.5+ syntax.
  # argv: <mode: size|hash> <venv path>. Prints one JSON object; exit 0 only when ok.
  const_set(:VERIFY_SCRIPT, <<-'PYTHON')
import base64, csv, hashlib, json, os, re, stat, sys
from email.parser import HeaderParser

MAX_ERRORS = 50


def main():
    mode, venv = sys.argv[1], sys.argv[2]
    errors = []
    dists = []
    files = 0

    def err(msg):
        errors.append(msg)

    prefix = os.path.realpath(sys.prefix)
    if prefix != os.path.realpath(venv):
        err('interpreter prefix %s is not the venv %s' % (prefix, venv))
    if sys.prefix == getattr(sys, 'base_prefix', sys.prefix):
        err('interpreter is not running inside a venv')

    pyver = 'python%d.%d' % sys.version_info[:2]
    roots = []
    for lib in ('lib', 'lib64'):
        root = os.path.join(sys.prefix, lib, pyver, 'site-packages')
        if os.path.isdir(root) and os.path.realpath(root) not in roots:
            roots.append(os.path.realpath(root))
    if not roots:
        err('no site-packages directory for %s' % pyver)

    for root in roots:
        for entry in sorted(os.listdir(root)):
            path = os.path.join(root, entry)
            if entry.endswith('.egg-info'):
                err('%s: legacy egg-info distribution cannot be verified' % path)
                continue
            if not entry.endswith('.dist-info'):
                continue
            try:
                with open(os.path.join(path, 'METADATA'), encoding='utf-8') as f:
                    meta = HeaderParser().parse(f)
                name, version = meta.get('Name'), meta.get('Version')
                if not name or not version:
                    err('%s: METADATA has no Name/Version' % path)
                    continue
                dists.append('%s==%s' % (re.sub(r'[-_.]+', '-', name).lower(), version))
                with open(os.path.join(path, 'RECORD'), encoding='utf-8', newline='') as f:
                    rows = [r for r in csv.reader(f) if r]
            except (OSError, ValueError, csv.Error) as e:
                err('%s: cannot read metadata: %s' % (path, e))
                continue
            if not rows:
                err('%s: RECORD is empty' % path)
                continue
            for row in rows:
                if len(row) != 3:
                    err('%s: malformed RECORD row %r' % (path, row))
                    continue
                rel, digest, size = row
                target = rel if os.path.isabs(rel) else os.path.normpath(os.path.join(root, rel))
                files += 1
                try:
                    st = os.stat(target)
                except OSError as e:
                    err('%s: missing (%s)' % (target, e.strerror))
                    continue
                if not stat.S_ISREG(st.st_mode):
                    err('%s: not a regular file' % target)
                    continue
                if size and int(size) != st.st_size:
                    err('%s: size %d, expected %s' % (target, st.st_size, size))
                    continue
                if mode != 'hash' or not digest:
                    continue
                algo, _, expected = digest.partition('=')
                try:
                    h = hashlib.new(algo)
                    with open(target, 'rb') as f:
                        for chunk in iter(lambda: f.read(1 << 20), b''):
                            h.update(chunk)
                except (OSError, ValueError) as e:
                    err('%s: cannot hash: %s' % (target, e))
                    continue
                actual = base64.urlsafe_b64encode(h.digest()).rstrip(b'=').decode('ascii')
                if actual != expected:
                    err('%s: %s mismatch' % (target, algo))

    return {
        'ok': not errors,
        'mode': mode,
        'python': '%d.%d' % sys.version_info[:2],
        'executable': os.path.realpath(sys.executable),
        'distributions': sorted(dists),
        'files': files,
        'error_count': len(errors),
        'errors': errors[:MAX_ERRORS],
    }


try:
    result = main()
except Exception as e:  # fail closed on anything unexpected
    result = {'ok': False, 'error_count': 1, 'errors': ['verifier crashed: %r' % (e,)]}
sys.stdout.write(json.dumps(result))
sys.exit(0 if result['ok'] else 1)
  PYTHON

  def self.default_python_cmd
    command(:python3)
  rescue Puppet::MissingCommand
    'python3'
  end

  def python_cmd
    resource[:python_executable] || self.class.default_python_cmd
  end

  # The stable path applications use: a symlink to the active build
  # (or, for venvs created by 0.1.0, the venv directory itself)
  def venv_path
    resource[:path]
  end

  # The venv being worked on: the build directory during a rebuild, otherwise venv_path
  def venv_dir
    @build_dir || venv_path
  end

  # Builds live next to venv_path, so switching the symlink is a same-filesystem rename
  def builds_dir
    File.join(File.dirname(venv_path), ".#{File.basename(venv_path)}.builds")
  end

  def pip_path
    File.join(venv_dir, 'bin', 'pip')
  end

  def python_venv_path
    File.join(venv_dir, 'bin', 'python')
  end

  def activate_path
    File.join(venv_dir, 'bin', 'activate')
  end

  def pyvenv_cfg_path
    File.join(venv_dir, 'pyvenv.cfg')
  end

  # Check that core venv files (not covered by any RECORD) are present and not zero-sized.
  # Sometimes python3 -m venv exits with code 0 but creates invalid venv with zero-sized files
  def venv_files_valid?
    [python_venv_path, pip_path, activate_path, pyvenv_cfg_path].each do |f|
      next if File.exist?(f) && File.size(f) > 0

      Puppet.warning("Invalid venv detected at #{venv_dir}: #{f} is missing or zero-sized")
      return false
    end
    true
  end

  def exists?
    File.directory?(venv_path) && File.executable?(python_venv_path) && File.executable?(pip_path) && venv_files_valid?
  end

  def create
    rebuild('venv is missing or incomplete')
  end

  def destroy
    remove_path(venv_path)
    fsync_dir(File.dirname(venv_path)) if File.directory?(File.dirname(venv_path))
    remove_path(builds_dir)
  end

  # Check if the venv is committed, matches the declared inputs and passes verification
  # (called by the requirements_state property)
  def requirements_in_sync?
    return true unless exists?

    out_of_sync_reason.nil?
  end

  # Make the venv match the declared state (called by the requirements_state property)
  def sync_requirements
    reason = out_of_sync_reason
    return if reason.nil?
    return if reason == self.class::LEGACY_STATE && adopt_legacy_state

    rebuild((reason == self.class::LEGACY_STATE) ? 'state from 0.1.0 failed verification' : reason)
  end

  # Path to store requirements state (the commit marker)
  def requirements_state_file
    File.join(venv_dir, '.requirements_state')
  end

  # Path to store individual requirements as a file
  def individual_requirements_file
    File.join(venv_dir, '.individual_requirements.txt')
  end

  # Load the commit marker. Returns nil when it is missing or unreadable.
  def load_requirements_state
    return nil unless File.exist?(requirements_state_file)

    state = JSON.parse(File.read(requirements_state_file))
    state.is_a?(Hash) ? state : nil
  rescue JSON::ParserError, SystemCallError, IOError => e
    Puppet.warning("Python venv #{venv_path}: state file is unreadable: #{e.message}")
    nil
  end

  # Returns nil when in sync, otherwise a reason (String) or LEGACY_STATE. Memoized per run.
  def out_of_sync_reason
    return @out_of_sync_reason if defined?(@out_of_sync_reason)

    @out_of_sync_reason = compute_out_of_sync_reason
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

  # Calculate expected requirements state (what should be installed).
  # Key layout is shared with the 0.1.0 state file so existing venvs can be adopted.
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

    state['system_site_packages'] = resource[:system_site_packages] ? true : false

    Puppet.debug("Calculated expected state: #{state.inspect}")
    state
  end

  # Run the RECORD verifier with the venv interpreter. Never raises; returns a Hash with 'ok'.
  def run_verifier(mode)
    output = execute([python_venv_path, '-I', '-c', self.class::VERIFY_SCRIPT, mode, venv_dir],
                     failonfail: false, combine: false)
    result = begin
      JSON.parse(output.to_s)
             rescue JSON::ParserError
               nil
    end
    status = output.respond_to?(:exitstatus) ? output.exitstatus : nil

    unless result.is_a?(Hash)
      return { 'ok' => false, 'errors' => ["verifier produced no result (exit status #{status.inspect})"] }
    end
    result['ok'] = false unless status == 0
    result
  rescue StandardError => e
    { 'ok' => false, 'errors' => ["verifier could not run: #{e.message}"] }
  end

  # Realpath of the interpreter the venv should be based on
  def resolved_base_python
    exe = python_cmd
    exe = Puppet::Util.which(exe) unless Puppet::Util.absolute_path?(exe)
    raise Puppet::Error, "Python executable not found: #{python_cmd}" unless exe && File.exist?(exe)

    File.realpath(exe)
  end

  private

  def requirements?
    !resource[:requirements].empty? || !resource[:requirements_files].empty?
  end

  def compute_out_of_sync_reason
    return 'venv is missing or incomplete' unless exists?

    # Errors here (missing requirements file, missing interpreter) propagate:
    # the resource fails and nothing on disk is touched.
    expected = calculate_expected_state
    base_python = resolved_base_python

    state = load_requirements_state
    return 'state marker is missing or unreadable' if state.nil?

    unless state['format'] == self.class::STATE_FORMAT
      return self.class::LEGACY_STATE if legacy_state_matches?(state, expected)
      return 'state marker has an unknown format'
    end

    unless state['inputs'] == expected
      log_input_changes(expected, state['inputs'].is_a?(Hash) ? state['inputs'] : {})
      return 'declared requirements changed'
    end

    interpreter = state['interpreter'].is_a?(Hash) ? state['interpreter'] : {}
    return "base python changed (#{interpreter['base_executable']} -> #{base_python})" if interpreter['base_executable'] != base_python

    return nil if resource[:verify] == :none

    result = run_verifier(resource[:verify].to_s)
    return "verification failed: #{format_errors(result)}" unless result['ok']
    if result['python'] != interpreter['python'] || result['executable'] != interpreter['executable']
      return "venv interpreter changed (#{interpreter['python']} -> #{result['python']})"
    end
    return 'installed distributions differ from the committed state' if result['distributions'] != state['distributions']

    nil
  end

  # A 0.1.0 state file: same requirement keys (no system_site_packages) plus pip_freeze_hash
  def legacy_state_matches?(state, expected)
    state.reject { |k, _| k == 'pip_freeze_hash' } == expected.reject { |k, _| k == 'system_site_packages' }
  end

  # A venv created by 0.1.0 with matching inputs is kept if it passes full verification
  def adopt_legacy_state
    Puppet.info("Python venv #{venv_path}: verifying venv created by an older module version")
    result = run_verifier('hash')
    unless result['ok']
      Puppet.warning("Python venv #{venv_path}: verification failed: #{format_errors(result)}")
      return false
    end

    write_state(calculate_expected_state, result)
    @out_of_sync_reason = nil
    Puppet.info("Python venv #{venv_path}: existing venv verified and adopted")
    true
  end

  # Build a new venv from scratch. A failed first attempt is retried once without the
  # pip cache, in case a cached wheel is corrupted.
  # * atomic => true: build next to the active venv and switch the symlink to it; the
  #   active venv is never modified, and stays in place if the build fails.
  # * atomic => false: delete the venv and build in place (one venv on disk); if the
  #   build fails, there is no venv until a later run succeeds.
  def rebuild(reason)
    # Computed before anything is touched, so invalid inputs never affect the venv
    expected = calculate_expected_state
    base_python = resolved_base_python

    if resource[:atomic]
      Puppet.notice("Python venv #{venv_path}: building a new venv next to the active one (#{reason})")
      remove_stale_builds
      dir = build_with_retry(expected, base_python) { new_build_dir(expected) }
      switch_to(dir)
      remove_stale_builds
    else
      Puppet.notice("Python venv #{venv_path}: rebuilding in place (#{reason})")
      dir = build_with_retry(expected, base_python) { clear_venv_path }
      remove_old_builds_dir
    end
    @out_of_sync_reason = nil
    Puppet.info("Python venv #{venv_path}: #{dir} built, flushed to disk and verified")
  end

  # The block returns the directory to build in
  def build_with_retry(expected, base_python)
    build(yield, expected, base_python, use_cache: true)
  rescue Puppet::Error => e
    Puppet.warning("Python venv #{venv_path}: build failed (#{e.message}); retrying without pip cache")
    build(yield, expected, base_python, use_cache: false)
  end

  # Build and commit a complete venv in dir; returns dir. dir is removed if anything fails.
  def build(dir, expected, base_python, use_cache:)
    @build_dir = dir

    create_venv
    install_all_requirements(use_cache) if requirements?
    flush_to_disk

    result = run_verifier('hash')
    raise Puppet::Error, "Verification of #{dir} failed after install: #{format_errors(result)}" unless result['ok']

    write_state(expected, result, base_python)
    dir
  rescue StandardError
    begin
      remove_path(dir)
    rescue StandardError => e
      Puppet.warning("Python venv #{venv_path}: could not remove failed build #{dir}: #{e.message}")
    end
    raise
  ensure
    @build_dir = nil
  end

  # For an in-place rebuild: remove the commit marker durably, then everything at
  # venv_path (a directory, or a symlink left by atomic => true). Returns venv_path.
  def clear_venv_path
    marker = File.join(venv_path, '.requirements_state')
    if File.exist?(marker)
      File.delete(marker)
      fsync_dir(File.dirname(marker))
    end
    remove_path(venv_path)
    venv_path
  end

  # Builds left over from atomic => true are not needed after an in-place rebuild
  def remove_old_builds_dir
    remove_path(builds_dir)
  rescue StandardError => e
    Puppet.warning("Python venv #{venv_path}: could not remove #{builds_dir}: #{e.message}")
  end

  # A unique, not yet existing build directory (unique so that a corrupted active
  # build can be replaced without touching it)
  def new_build_dir(expected)
    FileUtils.mkdir_p(builds_dir)
    inputs = Digest::SHA256.hexdigest(JSON.generate(expected))[0, 12]
    File.join(builds_dir, "#{inputs}-#{Time.now.utc.strftime('%Y%m%dT%H%M%S')}-#{SecureRandom.hex(4)}")
  end

  # Atomically point venv_path at build_dir: rename a new symlink over the old one.
  # A real directory at venv_path (a venv created by 0.1.0) is moved into builds_dir
  # just before, and deleted afterwards.
  def switch_to(build_dir)
    parent = File.dirname(venv_path)
    target = File.join(File.basename(builds_dir), File.basename(build_dir))
    link = File.join(parent, ".#{File.basename(venv_path)}.link.#{Process.pid}")

    File.delete(link) if File.symlink?(link)
    File.symlink(target, link)
    if File.directory?(venv_path) && !File.symlink?(venv_path)
      File.rename(venv_path, File.join(builds_dir, "retired-#{File.basename(build_dir)}"))
    end
    File.rename(link, venv_path)
    fsync_dir(parent)
  ensure
    File.delete(link) if link && File.symlink?(link)
  end

  # The build venv_path points to, or nil
  def active_build
    return nil unless File.symlink?(venv_path)

    target = File.expand_path(File.readlink(venv_path), File.dirname(venv_path))
    (File.dirname(target) == builds_dir) ? File.basename(target) : nil
  end

  # Remove every build except the active one (failed or interrupted builds, previous builds)
  def remove_stale_builds
    return unless File.directory?(builds_dir)

    keep = active_build
    Dir.children(builds_dir).each do |entry|
      next if entry == keep

      begin
        remove_path(File.join(builds_dir, entry))
      rescue StandardError => e
        Puppet.warning("Python venv #{venv_path}: could not remove old build #{entry}: #{e.message}")
      end
    end
  end

  # Raises if anything cannot be removed (unlike rm_rf, which ignores errors).
  # A symlink is removed itself, not its target.
  def remove_path(path)
    FileUtils.rm_r(path) if File.exist?(path) || File.symlink?(path)
  end

  def create_venv
    cmd = [python_cmd, '-m', 'venv']
    cmd << '--system-site-packages' if resource[:system_site_packages]
    cmd << venv_dir

    Puppet.info("Creating Python virtual environment at #{venv_path}")

    begin
      execute(cmd, failonfail: true, combine: true)
    rescue Puppet::ExecutionFailure => e
      raise Puppet::Error, "Failed to create virtual environment at #{venv_path}: #{e.message}"
    end

    # Verify venv was created successfully
    unless File.directory?(venv_dir) && File.executable?(python_venv_path) && File.executable?(pip_path)
      raise Puppet::Error, "Virtual environment creation appeared to succeed but #{venv_path} is not functional"
    end

    # Check for invalid venv with zero-sized files
    unless venv_files_valid?
      raise Puppet::Error, "Failed to create valid virtual environment at #{venv_path}: venv files are zero-sized (corrupted creation)"
    end

    # Upgrade pip to ensure we have latest features
    upgrade_pip
  end

  # Best effort: a failed upgrade keeps the bundled pip, and a pip broken by a partial
  # upgrade is caught by the RECORD verification before the venv is committed.
  def upgrade_pip
    Puppet.debug("Upgrading pip in #{venv_path}")
    begin
      execute([pip_path, 'install', '--upgrade', 'pip'], failonfail: true, combine: true)
    rescue Puppet::ExecutionFailure => e
      Puppet.warning("Failed to upgrade pip in #{venv_path}: #{e.message}")
    end
  end

  # Install all requirements. With resolve_together (default) one pip invocation gets all
  # files, so a single resolver sees all of them; otherwise each file gets its own
  # invocation, in order, so `--hash` lines in one file do not require hashes in the others.
  def install_all_requirements(use_cache)
    files_to_install = resource[:requirements_files].dup

    unless resource[:requirements].empty?
      File.write(individual_requirements_file, resource[:requirements].join("\n") + "\n")
      files_to_install << individual_requirements_file
    end

    if resource[:resolve_together]
      pip_install_requirements(files_to_install, use_cache)
    else
      files_to_install.each { |f| pip_install_requirements([f], use_cache) }
    end
  end

  def pip_install_requirements(files, use_cache)
    cmd = [pip_path, 'install']
    files.each { |f| cmd << '-r' << f }
    cmd += resource[:pip_args]
    cmd << '--no-cache-dir' unless use_cache || cmd.include?('--no-cache-dir')

    Puppet.info("Executing pip install: #{cmd.join(' ')}")

    begin
      output = execute(cmd, failonfail: true, combine: true)
      Puppet.debug("Pip install output: #{output}")
    rescue Puppet::ExecutionFailure => e
      raise Puppet::Error, "Failed to install requirements in #{venv_path}: #{e.message}"
    end
  end

  # Wait until everything written so far reaches the disk.
  # `sync -f` (syncfs) limits it to the venv's filesystem; plain `sync` is the fallback.
  def flush_to_disk
    execute(['sync', '-f', venv_dir], failonfail: true, combine: true)
  rescue Puppet::ExecutionFailure
    begin
      execute(['sync'], failonfail: true, combine: true)
    rescue Puppet::ExecutionFailure => e
      raise Puppet::Error, "Failed to flush #{venv_path} to disk: #{e.message}"
    end
  end

  def write_state(expected, result, base_python = resolved_base_python)
    state = {
      'format' => self.class::STATE_FORMAT,
      'inputs' => expected,
      'interpreter' => {
        'python' => result['python'],
        'executable' => result['executable'],
        'base_executable' => base_python,
      },
      'distributions' => result['distributions'],
      'files' => result['files'],
    }
    write_file_durably(requirements_state_file, JSON.pretty_generate(state) + "\n")
    Puppet.debug("Saved requirements state: #{state.inspect}")
  end

  # Write to a temp file, fsync it, rename over the target, fsync the directory
  def write_file_durably(path, content)
    tmp = "#{path}.tmp.#{Process.pid}"
    File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o644) do |f|
      f.write(content)
      f.flush
      f.fsync
    end
    File.rename(tmp, path)
    fsync_dir(File.dirname(path))
  ensure
    File.delete(tmp) if tmp && File.exist?(tmp)
  end

  def fsync_dir(dir)
    File.open(dir, File::RDONLY, &:fsync)
  end

  def format_errors(result)
    errors = Array(result['errors'])
    return 'unknown error' if errors.empty?

    count = result['error_count'] || errors.size
    shown = errors.first(5).join('; ')
    (count > 5) ? "#{shown}; ... (#{count} errors total)" : shown
  end

  # Log what changed in the declared inputs
  def log_input_changes(expected_state, actual_state)
    Puppet.info("Python venv #{venv_path}: Changes detected")

    keys = (expected_state.keys + actual_state.keys).uniq
    keys.each do |key|
      expected_value = expected_state[key]
      actual_value = actual_state[key]
      next if expected_value == actual_value

      if key.start_with?('file:')
        file_path = key.sub('file:', '')
        file_list_key = "file_list:#{file_path}"
        if expected_value.nil?
          Puppet.info("  - Requirements file removed: #{file_path}")
        elsif expected_state[file_list_key] && actual_state[file_list_key]
          log_requirement_list_changes("Requirements file: #{file_path}", expected_state[file_list_key], actual_state[file_list_key])
        else
          Puppet.info("  - Requirements file changed: #{file_path}")
        end
      elsif key == 'individual_requirements'
        log_requirement_list_changes('Individual requirements',
                                     expected_state['individual_requirements_list'] || [],
                                     actual_state['individual_requirements_list'] || [])
      elsif key == 'system_site_packages'
        Puppet.info("  - system_site_packages changed: #{actual_value.inspect} => #{expected_value.inspect}")
      end
    end
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
    added.each { |req| Puppet.info("      + #{req}") }
    removed.each { |req| Puppet.info("      - #{req}") }
    changed.each { |old_req, new_req| Puppet.info("      ~ #{old_req} => #{new_req}") }
  end

  # Parse package name from requirement string (e.g., "httpx==1.0.0" => "httpx")
  def parse_package_name(requirement)
    # Handle common requirement specifiers: ==, >=, <=, >, <, !=, ~=
    requirement.split(%r{[=<>!~]+}).first.strip.downcase
  end
end
