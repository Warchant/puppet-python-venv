# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'

describe Puppet::Type.type(:python_venv).provider(:pip) do
  let(:tmpdir) { Dir.mktmpdir('python_venv_spec') }
  let(:venv) { File.join(tmpdir, 'venv') }
  let(:req_file) { File.join(tmpdir, 'requirements.txt') }
  let(:base_python) { '/usr/bin/python3.11' }
  let(:verify) { :size }
  let(:resource_params) do
    {
      path: venv,
      python_executable: '/usr/bin/python3',
      requirements: ['requests==2.28.1', 'flask==2.2.2'],
      requirements_files: [req_file],
      pip_args: ['--index-url', 'https://mirror.example/simple'],
      verify: verify,
    }
  end
  let(:resource) { Puppet::Type.type(:python_venv).new(resource_params) }
  let(:provider) { described_class.new(resource) }

  let(:verifier_ok) do
    {
      'ok' => true,
      'python' => '3.11',
      'executable' => base_python,
      'distributions' => ['flask==2.2.2', 'pip==24.0', 'requests==2.28.1'],
      'files' => 1234,
    }
  end

  # Lay out the files exists? looks at, as python -m venv would
  def make_venv(dir)
    FileUtils.mkdir_p(File.join(dir, 'bin'))
    ['bin/python', 'bin/pip', 'bin/activate', 'pyvenv.cfg'].each do |f|
      path = File.join(dir, f)
      File.write(path, "content\n")
      File.chmod(0o755, path)
    end
  end

  def state_file
    File.join(venv, '.requirements_state')
  end

  def write_committed_state(overrides = {})
    state = {
      'format' => 2,
      'inputs' => provider.calculate_expected_state,
      'interpreter' => { 'python' => '3.11', 'executable' => base_python, 'base_executable' => base_python },
      'distributions' => verifier_ok['distributions'],
      'files' => 1234,
    }.merge(overrides)
    File.write(state_file, JSON.generate(state))
  end

  def process_output(text, status)
    Puppet::Util::Execution::ProcessOutput.new(text, status)
  end

  before(:each) do
    File.write(req_file, "six==1.16.0\n# comment\n")
    allow(provider).to receive(:resolved_base_python).and_return(base_python)
  end

  after(:each) { FileUtils.rm_rf(tmpdir) }

  describe '#exists?' do
    it 'is true for a complete venv' do
      make_venv(venv)
      expect(provider.exists?).to be true
    end

    it 'is false when the directory is missing' do
      expect(provider.exists?).to be false
    end

    ['bin/python', 'bin/pip', 'bin/activate', 'pyvenv.cfg'].each do |f|
      it "is false when #{f} is zero-sized" do
        make_venv(venv)
        File.write(File.join(venv, f), '')
        expect(provider.exists?).to be false
      end
    end

    it 'is false when pyvenv.cfg is missing' do
      make_venv(venv)
      File.delete(File.join(venv, 'pyvenv.cfg'))
      expect(provider.exists?).to be false
    end
  end

  describe '#calculate_expected_state' do
    it 'tracks files, individual requirements and system_site_packages' do
      state = provider.calculate_expected_state
      expect(state["file:#{req_file}"]).to eq(Digest::SHA256.hexdigest(File.read(req_file)))
      expect(state["file_list:#{req_file}"]).to eq(['six==1.16.0'])
      expect(state['individual_requirements_list']).to eq(['flask==2.2.2', 'requests==2.28.1'])
      expect(state['system_site_packages']).to be false
    end

    it 'raises when a requirements file is missing' do
      File.delete(req_file)
      expect { provider.calculate_expected_state }.to raise_error(Puppet::Error, %r{does not exist})
    end
  end

  describe '#requirements_in_sync?' do
    before(:each) do
      make_venv(venv)
      allow(provider).to receive(:run_verifier).and_return(verifier_ok)
    end

    it 'is true when the venv does not exist (ensure handles it)' do
      FileUtils.rm_rf(venv)
      expect(provider.requirements_in_sync?).to be true
    end

    it 'is true when committed, unchanged and verified' do
      write_committed_state
      expect(provider).to receive(:run_verifier).with('size').and_return(verifier_ok)
      expect(provider.requirements_in_sync?).to be true
    end

    it 'is false when the commit marker is missing' do
      expect(provider.requirements_in_sync?).to be false
      expect(provider.out_of_sync_reason).to match(%r{marker is missing})
    end

    it 'is false when the commit marker is corrupted' do
      File.write(state_file, '{"format": 2, "inpu')
      expect(provider.requirements_in_sync?).to be false
    end

    it 'is false when the commit marker is zero-sized' do
      File.write(state_file, '')
      expect(provider.requirements_in_sync?).to be false
    end

    it 'is false when a requirement changes' do
      write_committed_state
      File.write(req_file, "six==1.17.0\n")
      expect(provider.requirements_in_sync?).to be false
      expect(provider.out_of_sync_reason).to eq('declared requirements changed')
    end

    it 'is false when a requirements file is removed from the resource' do
      write_committed_state
      resource[:requirements_files] = []
      expect(provider.requirements_in_sync?).to be false
    end

    it 'is false when system_site_packages changes' do
      write_committed_state
      resource[:system_site_packages] = true
      expect(provider.requirements_in_sync?).to be false
    end

    it 'is false when the base python changes' do
      write_committed_state
      allow(provider).to receive(:resolved_base_python).and_return('/usr/bin/python3.12')
      expect(provider.requirements_in_sync?).to be false
      expect(provider.out_of_sync_reason).to match(%r{base python changed})
    end

    it 'is false when verification fails' do
      write_committed_state
      allow(provider).to receive(:run_verifier).and_return('ok' => false, 'errors' => ['/x/six.py: size 0, expected 34549'])
      expect(provider.requirements_in_sync?).to be false
      expect(provider.out_of_sync_reason).to match(%r{verification failed: /x/six.py: size 0})
    end

    it 'is false when installed distributions differ from the committed state' do
      write_committed_state
      allow(provider).to receive(:run_verifier).and_return(verifier_ok.merge('distributions' => ['flask==2.2.2']))
      expect(provider.requirements_in_sync?).to be false
    end

    it 'is false when the venv interpreter differs from the committed one' do
      write_committed_state
      allow(provider).to receive(:run_verifier).and_return(verifier_ok.merge('python' => '3.12'))
      expect(provider.requirements_in_sync?).to be false
    end

    context 'with verify => hash' do
      let(:verify) { :hash }

      it 'runs the full hash check' do
        write_committed_state
        expect(provider).to receive(:run_verifier).with('hash').and_return(verifier_ok)
        expect(provider.requirements_in_sync?).to be true
      end
    end

    context 'with verify => none' do
      let(:verify) { :none }

      it 'does not run the verifier' do
        write_committed_state
        expect(provider).not_to receive(:run_verifier)
        expect(provider.requirements_in_sync?).to be true
      end
    end

    context 'with a state file from 0.1.0' do
      def write_legacy_state(inputs)
        File.write(state_file, JSON.generate(inputs.merge('pip_freeze_hash' => 'abc')))
      end

      it 'reports it for adoption when the requirements match' do
        write_legacy_state(provider.calculate_expected_state.reject { |k, _| k == 'system_site_packages' })
        expect(provider.requirements_in_sync?).to be false
        expect(provider.out_of_sync_reason).to eq(described_class::LEGACY_STATE)
      end

      it 'reports a rebuild when the requirements differ' do
        write_legacy_state('individual_requirements_list' => ['other==1.0'])
        expect(provider.out_of_sync_reason).to match(%r{unknown format})
      end
    end

    it 'propagates a missing requirements file instead of reporting out of sync' do
      write_committed_state
      File.delete(req_file)
      expect { provider.requirements_in_sync? }.to raise_error(Puppet::Error, %r{does not exist})
    end
  end

  describe '#run_verifier' do
    before(:each) { make_venv(venv) }

    it 'runs the venv python in isolated mode with mode and venv path' do
      expect(provider).to receive(:execute).with(
        [File.join(venv, 'bin', 'python'), '-I', '-c', described_class::VERIFY_SCRIPT, 'hash', venv],
        failonfail: false, combine: false,
      ).and_return(process_output(JSON.generate(verifier_ok), 0))
      expect(provider.run_verifier('hash')['ok']).to be true
    end

    it 'fails on a non-zero exit status even if the output says ok' do
      allow(provider).to receive(:execute).and_return(process_output(JSON.generate(verifier_ok), 1))
      expect(provider.run_verifier('size')['ok']).to be false
    end

    it 'fails when the output is not JSON (e.g. the interpreter crashed)' do
      allow(provider).to receive(:execute).and_return(process_output('ImportError: bad magic number', 1))
      result = provider.run_verifier('size')
      expect(result['ok']).to be false
      expect(result['errors'].first).to match(%r{no result})
    end

    it 'fails when the interpreter cannot be executed' do
      allow(provider).to receive(:execute).and_raise(Errno::ENOEXEC)
      expect(provider.run_verifier('size')['ok']).to be false
    end
  end

  describe '#create with atomic => true (build aside, then switch)' do
    let(:resource_params) { super().merge(atomic: true) }
    let(:commands) { [] }
    let(:verifier_results) { [verifier_ok] }
    let(:verifier_modes) { [] }
    let(:builds) { File.join(tmpdir, '.venv.builds') }

    # python -m venv <dir> creates the venv in the build directory passed to it
    def stub_execute(fail_on: nil, zero_sized: nil)
      allow(provider).to receive(:execute) do |cmd, _opts|
        commands << cmd
        if cmd[1..2] == ['-m', 'venv']
          make_venv(cmd.last)
          File.write(File.join(cmd.last, zero_sized), '') if zero_sized
        end
        raise Puppet::ExecutionFailure, "#{cmd.join(' ')} failed" if fail_on&.call(cmd)
        process_output('', 0)
      end
    end

    def build_dirs
      Dir.exist?(builds) ? Dir.children(builds).sort : []
    end

    before(:each) do
      stub_execute
      allow(provider).to receive(:run_verifier) do |mode|
        verifier_modes << mode
        (verifier_results.length > 1) ? verifier_results.shift : verifier_results.first
      end
    end

    it 'builds in a new directory, installs once, flushes, verifies, commits and switches' do
      provider.create

      expect(File.symlink?(venv)).to be true
      expect(build_dirs.size).to eq(1)
      build = File.join(builds, build_dirs.first)
      expect(File.readlink(venv)).to eq(File.join('.venv.builds', build_dirs.first))

      venv_cmd = ['/usr/bin/python3', '-m', 'venv', build]
      install_cmd = [File.join(build, 'bin', 'pip'), 'install', '-r', req_file,
                     '-r', File.join(build, '.individual_requirements.txt'),
                     '--index-url', 'https://mirror.example/simple']
      sync_cmd = ['sync', '-f', build]
      expect(commands).to eq([venv_cmd, [File.join(build, 'bin', 'pip'), 'install', '--upgrade', 'pip'], install_cmd, sync_cmd])
      expect(verifier_modes).to eq(['hash'])

      state = JSON.parse(File.read(state_file))
      expect(state['format']).to eq(2)
      expect(state['inputs']).to eq(provider.calculate_expected_state)
      expect(state['interpreter']).to eq('python' => '3.11', 'executable' => base_python, 'base_executable' => base_python)
      expect(state['distributions']).to eq(verifier_ok['distributions'])
      expect(Dir.glob(File.join(build, '.requirements_state.tmp*'))).to be_empty
      expect(Dir.glob(File.join(tmpdir, '.venv.link*'))).to be_empty
    end

    it 'commits the build before switching to it' do
      marker_at_switch = nil
      allow(File).to receive(:rename).and_wrap_original do |m, from, to|
        marker_at_switch = File.exist?(File.join(from, '.requirements_state')) if to == venv
        m.call(from, to)
      end
      provider.create
      expect(marker_at_switch).to be true
    end

    it 'replaces the previous build and removes it after switching' do
      provider.create
      old = build_dirs.first
      File.write(req_file, "six==1.17.0\n")
      provider.create
      expect(build_dirs.size).to eq(1)
      expect(build_dirs.first).not_to eq(old)
      expect(File.readlink(venv)).to end_with(build_dirs.first)
    end

    it 'removes leftovers of interrupted builds' do
      FileUtils.mkdir_p(File.join(builds, 'interrupted'))
      provider.create
      expect(build_dirs).not_to include('interrupted')
    end

    it 'moves a venv directory created by 0.1.0 out of the way and deletes it' do
      make_venv(venv)
      File.write(File.join(venv, 'stale'), 'x')
      write_committed_state
      provider.create
      expect(File.symlink?(venv)).to be true
      expect(File.exist?(File.join(venv, 'stale'))).to be false
      expect(build_dirs.size).to eq(1)
    end

    it 'replaces a dangling symlink' do
      FileUtils.mkdir_p(tmpdir)
      File.symlink('.venv.builds/gone', venv)
      provider.create
      expect(File.exist?(File.join(venv, 'pyvenv.cfg'))).to be true
    end

    it 'falls back to plain sync when sync -f is not supported' do
      stub_execute(fail_on: ->(cmd) { cmd[0..1] == ['sync', '-f'] })
      provider.create
      expect(commands).to include(['sync'])
      expect(File.symlink?(venv)).to be true
    end

    it 'continues when the pip upgrade fails (verification still guards the result)' do
      stub_execute(fail_on: ->(cmd) { cmd.include?('--upgrade') })
      provider.create
      expect(File.symlink?(venv)).to be true
    end

    context 'when the first attempt fails verification' do
      let(:verifier_results) { [{ 'ok' => false, 'errors' => ['six.py: sha256 mismatch'] }, verifier_ok] }

      it 'builds again without the pip cache, switches, and removes the failed build' do
        provider.create
        installs = commands.select { |c| c[1] == 'install' && c.include?('-r') }
        expect(installs.size).to eq(2)
        expect(installs.first).not_to include('--no-cache-dir')
        expect(installs.last.last).to eq('--no-cache-dir')
        expect(build_dirs.size).to eq(1)
        expect(File.exist?(state_file)).to be true
      end
    end

    # `break_build` makes every following build fail with `message`
    shared_examples 'a failed build' do |message|
      it 'fails, keeps the active venv and removes the failed build' do
        provider.create
        active = File.readlink(venv)
        File.write(req_file, "six==1.17.0\n")
        break_build
        expect { provider.create }.to raise_error(Puppet::Error, message)
        expect(File.readlink(venv)).to eq(active)
        expect(File.exist?(state_file)).to be true
        expect(build_dirs).to eq([File.basename(active)])
      end

      it 'fails without creating the venv when there is none yet' do
        break_build
        expect { provider.create }.to raise_error(Puppet::Error, message)
        expect(File.exist?(venv) || File.symlink?(venv)).to be false
        expect(build_dirs).to be_empty
      end
    end

    context 'when verification keeps failing' do
      def break_build
        allow(provider).to receive(:run_verifier).and_return('ok' => false, 'errors' => ['six.py: sha256 mismatch'])
      end

      it_behaves_like 'a failed build', %r{sha256 mismatch}
    end

    context 'when pip install fails' do
      def break_build
        stub_execute(fail_on: ->(cmd) { cmd.include?('-r') })
      end

      it_behaves_like 'a failed build', %r{Failed to install requirements}
    end

    context 'when the disk cannot be flushed' do
      def break_build
        stub_execute(fail_on: ->(cmd) { cmd.first == 'sync' })
      end

      it_behaves_like 'a failed build', %r{flush}
    end

    it 'fails when python -m venv produces zero-sized files' do
      stub_execute(zero_sized: 'bin/activate')
      expect { provider.create }.to raise_error(Puppet::Error, %r{zero-sized})
      expect(build_dirs).to be_empty
    end

    it 'does not touch anything when a requirements file is missing' do
      make_venv(venv)
      File.delete(req_file)
      expect { provider.create }.to raise_error(Puppet::Error, %r{does not exist})
      expect(File.exist?(File.join(venv, 'pyvenv.cfg'))).to be true
      expect(commands).to be_empty
      expect(Dir.exist?(builds)).to be false
    end

    context 'without requirements' do
      let(:resource_params) { { path: venv, python_executable: '/usr/bin/python3' } }

      it 'still verifies and commits the venv' do
        provider.create
        expect(commands.none? { |c| c.include?('-r') }).to be true
        expect(verifier_modes).to eq(['hash'])
        expect(File.exist?(state_file)).to be true
      end
    end
  end

  describe '#create with atomic => false (default: rebuild in place)' do
    let(:commands) { [] }
    let(:verifier_results) { [verifier_ok] }
    let(:builds) { File.join(tmpdir, '.venv.builds') }

    def stub_execute(fail_on: nil)
      allow(provider).to receive(:execute) do |cmd, _opts|
        commands << cmd
        make_venv(cmd.last) if cmd[1..2] == ['-m', 'venv']
        raise Puppet::ExecutionFailure, "#{cmd.join(' ')} failed" if fail_on&.call(cmd)
        process_output('', 0)
      end
    end

    before(:each) do
      stub_execute
      allow(provider).to receive(:run_verifier) { (verifier_results.length > 1) ? verifier_results.shift : verifier_results.first }
    end

    it 'builds at the venv path itself, without a builds directory' do
      provider.create
      expect(File.directory?(venv) && !File.symlink?(venv)).to be true
      expect(commands.first).to eq(['/usr/bin/python3', '-m', 'venv', venv])
      expect(commands).to include(['sync', '-f', venv])
      expect(JSON.parse(File.read(state_file))['format']).to eq(2)
      expect(Dir.exist?(builds)).to be false
    end

    it 'deletes the existing venv, including stale packages, before building' do
      make_venv(venv)
      File.write(File.join(venv, 'stale'), 'x')
      write_committed_state
      provider.create
      expect(File.exist?(File.join(venv, 'stale'))).to be false
      expect(File.exist?(state_file)).to be true
    end

    it 'removes the commit marker before deleting the venv' do
      make_venv(venv)
      write_committed_state
      marker_gone_at_rm = nil
      allow(FileUtils).to receive(:rm_r).and_wrap_original do |m, path, **opts|
        marker_gone_at_rm = !File.exist?(state_file) if path == venv
        m.call(path, **opts)
      end
      provider.create
      expect(marker_gone_at_rm).to be true
    end

    it 'replaces a venv built with atomic => true and removes its builds' do
      make_venv(File.join(builds, 'b1'))
      File.symlink('.venv.builds/b1', venv)
      provider.create
      expect(File.directory?(venv) && !File.symlink?(venv)).to be true
      expect(Dir.exist?(builds)).to be false
    end

    context 'when the first attempt fails verification' do
      let(:verifier_results) { [{ 'ok' => false, 'errors' => ['six.py: sha256 mismatch'] }, verifier_ok] }

      it 'rebuilds again without the pip cache and commits' do
        provider.create
        installs = commands.select { |c| c[1] == 'install' && c.include?('-r') }
        expect(installs.map(&:last)).to eq(['https://mirror.example/simple', '--no-cache-dir'])
        expect(File.exist?(state_file)).to be true
      end
    end

    it 'fails and leaves no venv when the build keeps failing' do
      make_venv(venv)
      write_committed_state
      File.write(req_file, "six==1.17.0\n")
      stub_execute(fail_on: ->(cmd) { cmd.include?('-r') })
      expect { provider.create }.to raise_error(Puppet::Error, %r{Failed to install requirements})
      expect(File.exist?(venv)).to be false
    end

    it 'does not touch the venv when a requirements file is missing' do
      make_venv(venv)
      File.delete(req_file)
      expect { provider.create }.to raise_error(Puppet::Error, %r{does not exist})
      expect(File.exist?(File.join(venv, 'pyvenv.cfg'))).to be true
      expect(commands).to be_empty
    end
  end

  describe '#sync_requirements' do
    before(:each) do
      make_venv(venv)
      allow(provider).to receive(:run_verifier).and_return(verifier_ok)
    end

    it 'does nothing when in sync' do
      write_committed_state
      expect(provider).not_to receive(:rebuild)
      provider.sync_requirements
    end

    it 'rebuilds when out of sync' do
      expect(provider).to receive(:rebuild).with(%r{marker is missing})
      provider.sync_requirements
    end

    it 'does not check again after a rebuild in the same run' do
      allow(provider).to receive(:execute) do |cmd, _opts|
        make_venv(cmd.last) if cmd[1..2] == ['-m', 'venv']
        process_output('', 0)
      end
      FileUtils.rm_rf(venv)
      expect(provider).to receive(:run_verifier).once.and_return(verifier_ok)
      provider.create
      provider.sync_requirements
    end

    context 'with a matching 0.1.0 state file' do
      before(:each) do
        legacy = provider.calculate_expected_state.reject { |k, _| k == 'system_site_packages' }
        File.write(state_file, JSON.generate(legacy.merge('pip_freeze_hash' => 'abc')))
      end

      it 'adopts the venv when it passes full verification' do
        expect(provider).not_to receive(:rebuild)
        expect(provider).to receive(:run_verifier).with('hash').and_return(verifier_ok)
        provider.sync_requirements
        expect(JSON.parse(File.read(state_file))['format']).to eq(2)
      end

      it 'rebuilds the venv when it fails verification' do
        allow(provider).to receive(:run_verifier).and_return('ok' => false, 'errors' => ['broken'])
        expect(provider).to receive(:rebuild).with(%r{0\.1\.0 failed verification})
        provider.sync_requirements
      end
    end
  end

  describe '#destroy' do
    it 'removes a venv created by 0.1.0' do
      make_venv(venv)
      provider.destroy
      expect(File.exist?(venv)).to be false
    end

    it 'removes the symlink and all builds' do
      builds = File.join(tmpdir, '.venv.builds')
      make_venv(File.join(builds, 'b1'))
      File.symlink('.venv.builds/b1', venv)
      provider.destroy
      expect(File.symlink?(venv)).to be false
      expect(Dir.exist?(builds)).to be false
    end
  end
end
