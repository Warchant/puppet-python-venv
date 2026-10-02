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

  describe '#create (rebuild from scratch)' do
    let(:commands) { [] }
    let(:verifier_results) { [verifier_ok] }
    let(:verifier_modes) { [] }

    before(:each) do
      allow(provider).to receive(:execute) do |cmd, _opts|
        commands << cmd
        make_venv(venv) if cmd[1..2] == ['-m', 'venv']
        process_output('', 0)
      end
      allow(provider).to receive(:run_verifier) do |mode|
        verifier_modes << mode
        (verifier_results.length > 1) ? verifier_results.shift : verifier_results.first
      end
    end

    it 'creates, installs once, flushes to disk, verifies and commits' do
      provider.create

      venv_cmd = ['/usr/bin/python3', '-m', 'venv', venv]
      install_cmd = [File.join(venv, 'bin', 'pip'), 'install', '-r', req_file,
                     '-r', File.join(venv, '.individual_requirements.txt'),
                     '--index-url', 'https://mirror.example/simple']
      sync_cmd = ['sync', '-f', venv]
      expect(commands).to eq([venv_cmd, [File.join(venv, 'bin', 'pip'), 'install', '--upgrade', 'pip'], install_cmd, sync_cmd])
      expect(verifier_modes).to eq(['hash'])

      state = JSON.parse(File.read(state_file))
      expect(state['format']).to eq(2)
      expect(state['inputs']).to eq(provider.calculate_expected_state)
      expect(state['interpreter']).to eq('python' => '3.11', 'executable' => base_python, 'base_executable' => base_python)
      expect(state['distributions']).to eq(verifier_ok['distributions'])
      expect(Dir.glob("#{state_file}.tmp*")).to be_empty
    end

    it 'deletes an existing venv, including stale packages, before creating it' do
      make_venv(venv)
      File.write(File.join(venv, 'stale'), 'x')
      write_committed_state
      provider.create
      expect(File.exist?(File.join(venv, 'stale'))).to be false
    end

    it 'removes the commit marker before deleting the venv' do
      make_venv(venv)
      write_committed_state
      marker_gone_at_rm = nil
      allow(FileUtils).to receive(:rm_r).and_wrap_original do |m, path, **opts|
        marker_gone_at_rm = !File.exist?(state_file)
        m.call(path, **opts)
      end
      provider.create
      expect(marker_gone_at_rm).to be true
    end

    it 'falls back to plain sync when sync -f is not supported' do
      allow(provider).to receive(:execute) do |cmd, _opts|
        commands << cmd
        make_venv(venv) if cmd[1..2] == ['-m', 'venv']
        raise Puppet::ExecutionFailure, 'sync: invalid option' if cmd == ['sync', '-f', venv]
        process_output('', 0)
      end
      provider.create
      expect(commands).to include(['sync'])
      expect(File.exist?(state_file)).to be true
    end

    it 'fails without committing when the disk cannot be flushed' do
      allow(provider).to receive(:execute) do |cmd, _opts|
        make_venv(venv) if cmd[1..2] == ['-m', 'venv']
        raise Puppet::ExecutionFailure, 'sync failed' if cmd.first == 'sync'
        process_output('', 0)
      end
      expect { provider.create }.to raise_error(Puppet::Error, %r{flush})
      expect(File.exist?(state_file)).to be false
    end

    it 'continues when the pip upgrade fails (verification still guards the result)' do
      allow(provider).to receive(:execute) do |cmd, _opts|
        commands << cmd
        make_venv(venv) if cmd[1..2] == ['-m', 'venv']
        raise Puppet::ExecutionFailure, 'offline' if cmd.include?('--upgrade')
        process_output('', 0)
      end
      provider.create
      expect(File.exist?(state_file)).to be true
    end

    context 'when the first attempt fails verification' do
      let(:verifier_results) { [{ 'ok' => false, 'errors' => ['six.py: sha256 mismatch'] }, verifier_ok] }

      it 'rebuilds again without the pip cache and commits' do
        provider.create
        installs = commands.select { |c| c[1] == 'install' && c.include?('-r') }
        expect(installs.size).to eq(2)
        expect(installs.first).not_to include('--no-cache-dir')
        expect(installs.last.last).to eq('--no-cache-dir')
        expect(File.exist?(state_file)).to be true
      end
    end

    context 'when verification keeps failing' do
      let(:verifier_results) { [{ 'ok' => false, 'errors' => ['six.py: sha256 mismatch'] }] }

      it 'fails and leaves no commit marker' do
        expect { provider.create }.to raise_error(Puppet::Error, %r{sha256 mismatch})
        expect(File.exist?(state_file)).to be false
      end
    end

    it 'fails and leaves no commit marker when pip install fails' do
      allow(provider).to receive(:execute) do |cmd, _opts|
        make_venv(venv) if cmd[1..2] == ['-m', 'venv']
        raise Puppet::ExecutionFailure, 'No matching distribution' if cmd.include?('-r')
        process_output('', 0)
      end
      expect { provider.create }.to raise_error(Puppet::Error, %r{No matching distribution})
      expect(File.exist?(state_file)).to be false
    end

    it 'fails when python -m venv produces zero-sized files' do
      allow(provider).to receive(:execute) do |cmd, _opts|
        if cmd[1..2] == ['-m', 'venv']
          make_venv(venv)
          File.write(File.join(venv, 'bin', 'activate'), '')
        end
        process_output('', 0)
      end
      expect { provider.create }.to raise_error(Puppet::Error, %r{zero-sized})
      expect(File.exist?(state_file)).to be false
    end

    it 'does not touch an existing venv when a requirements file is missing' do
      make_venv(venv)
      File.delete(req_file)
      expect { provider.create }.to raise_error(Puppet::Error, %r{does not exist})
      expect(File.exist?(File.join(venv, 'pyvenv.cfg'))).to be true
      expect(commands).to be_empty
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
        make_venv(venv) if cmd[1..2] == ['-m', 'venv']
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
    it 'removes the venv' do
      make_venv(venv)
      provider.destroy
      expect(File.exist?(venv)).to be false
    end
  end
end
