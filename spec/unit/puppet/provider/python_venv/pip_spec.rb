# frozen_string_literal: true

require 'spec_helper'

describe Puppet::Type.type(:python_venv).provider(:pip) do
  let(:resource) do
    Puppet::Type.type(:python_venv).new(
      path: '/opt/test-venv',
      python_executable: '/usr/bin/python3',
      system_site_packages: false,
      requirements: ['requests==2.28.1', 'flask==2.2.2'],
      requirements_files: ['/opt/requirements.txt'],
      pip_args: ['--no-cache-dir'],
    )
  end

  let(:provider) { described_class.new(resource) }

  describe '#exists?' do
    context 'when venv exists and is functional' do
      before(:each) do
        allow(File).to receive(:directory?).with('/opt/test-venv').and_return(true)
        allow(File).to receive(:executable?).with('/opt/test-venv/bin/python').and_return(true)
        allow(File).to receive(:executable?).with('/opt/test-venv/bin/pip').and_return(true)
        allow(File).to receive(:exist?).with('/opt/test-venv/bin/python').and_return(true)
        allow(File).to receive(:exist?).with('/opt/test-venv/bin/activate').and_return(true)
        allow(File).to receive(:size).with('/opt/test-venv/bin/python').and_return(100)
        allow(File).to receive(:size).with('/opt/test-venv/bin/activate').and_return(200)
      end

      it 'returns true' do
        expect(provider.exists?).to be true
      end
    end

    context 'when venv directory does not exist' do
      before(:each) do
        allow(File).to receive(:directory?).with('/opt/test-venv').and_return(false)
      end

      it 'returns false' do
        expect(provider.exists?).to be false
      end
    end

    context 'when venv directory exists but executables are missing' do
      before(:each) do
        allow(File).to receive(:directory?).with('/opt/test-venv').and_return(true)
        allow(File).to receive(:executable?).with('/opt/test-venv/bin/python').and_return(false)
        allow(File).to receive(:executable?).with('/opt/test-venv/bin/pip').and_return(false)
      end

      it 'returns false' do
        expect(provider.exists?).to be false
      end
    end

    context 'when venv has zero-sized python file' do
      before(:each) do
        allow(File).to receive(:directory?).with('/opt/test-venv').and_return(true)
        allow(File).to receive(:executable?).with('/opt/test-venv/bin/python').and_return(true)
        allow(File).to receive(:executable?).with('/opt/test-venv/bin/pip').and_return(true)
        allow(File).to receive(:exist?).with('/opt/test-venv/bin/python').and_return(true)
        allow(File).to receive(:exist?).with('/opt/test-venv/bin/activate').and_return(true)
        allow(File).to receive(:size).with('/opt/test-venv/bin/python').and_return(0)
        allow(File).to receive(:size).with('/opt/test-venv/bin/activate').and_return(200)
      end

      it 'returns false' do
        expect(Puppet).to receive(:warning).with(%r{Invalid venv detected.*python size=0})
        expect(provider.exists?).to be false
      end
    end

    context 'when venv has zero-sized activate file' do
      before(:each) do
        allow(File).to receive(:directory?).with('/opt/test-venv').and_return(true)
        allow(File).to receive(:executable?).with('/opt/test-venv/bin/python').and_return(true)
        allow(File).to receive(:executable?).with('/opt/test-venv/bin/pip').and_return(true)
        allow(File).to receive(:exist?).with('/opt/test-venv/bin/python').and_return(true)
        allow(File).to receive(:exist?).with('/opt/test-venv/bin/activate').and_return(true)
        allow(File).to receive(:size).with('/opt/test-venv/bin/python').and_return(100)
        allow(File).to receive(:size).with('/opt/test-venv/bin/activate').and_return(0)
      end

      it 'returns false' do
        expect(Puppet).to receive(:warning).with(%r{Invalid venv detected.*activate size=0})
        expect(provider.exists?).to be false
      end
    end

    context 'when venv has both python and activate zero-sized' do
      before(:each) do
        allow(File).to receive(:directory?).with('/opt/test-venv').and_return(true)
        allow(File).to receive(:executable?).with('/opt/test-venv/bin/python').and_return(true)
        allow(File).to receive(:executable?).with('/opt/test-venv/bin/pip').and_return(true)
        allow(File).to receive(:exist?).with('/opt/test-venv/bin/python').and_return(true)
        allow(File).to receive(:exist?).with('/opt/test-venv/bin/activate').and_return(true)
        allow(File).to receive(:size).with('/opt/test-venv/bin/python').and_return(0)
        allow(File).to receive(:size).with('/opt/test-venv/bin/activate').and_return(0)
      end

      it 'returns false' do
        expect(Puppet).to receive(:warning).with(%r{Invalid venv detected.*python size=0.*activate size=0})
        expect(provider.exists?).to be false
      end
    end
  end

  describe '#venv_files_valid?' do
    context 'when python and activate files exist with non-zero size' do
      before(:each) do
        allow(File).to receive(:exist?).with('/opt/test-venv/bin/python').and_return(true)
        allow(File).to receive(:exist?).with('/opt/test-venv/bin/activate').and_return(true)
        allow(File).to receive(:size).with('/opt/test-venv/bin/python').and_return(150)
        allow(File).to receive(:size).with('/opt/test-venv/bin/activate').and_return(250)
      end

      it 'returns true' do
        expect(provider.send(:venv_files_valid?)).to be true
      end
    end

    context 'when python file does not exist' do
      before(:each) do
        allow(File).to receive(:exist?).with('/opt/test-venv/bin/python').and_return(false)
        allow(File).to receive(:exist?).with('/opt/test-venv/bin/activate').and_return(true)
      end

      it 'returns false' do
        expect(provider.send(:venv_files_valid?)).to be false
      end
    end

    context 'when activate file does not exist' do
      before(:each) do
        allow(File).to receive(:exist?).with('/opt/test-venv/bin/python').and_return(true)
        allow(File).to receive(:exist?).with('/opt/test-venv/bin/activate').and_return(false)
      end

      it 'returns false' do
        expect(provider.send(:venv_files_valid?)).to be false
      end
    end

    context 'when python file has zero size' do
      before(:each) do
        allow(File).to receive(:exist?).with('/opt/test-venv/bin/python').and_return(true)
        allow(File).to receive(:exist?).with('/opt/test-venv/bin/activate').and_return(true)
        allow(File).to receive(:size).with('/opt/test-venv/bin/python').and_return(0)
        allow(File).to receive(:size).with('/opt/test-venv/bin/activate').and_return(250)
      end

      it 'returns false and logs warning' do
        expect(Puppet).to receive(:warning).with(/Invalid venv detected at \/opt\/test-venv: python size=0, activate size=250/)
        expect(provider.send(:venv_files_valid?)).to be false
      end
    end

    context 'when activate file has zero size' do
      before(:each) do
        allow(File).to receive(:exist?).with('/opt/test-venv/bin/python').and_return(true)
        allow(File).to receive(:exist?).with('/opt/test-venv/bin/activate').and_return(true)
        allow(File).to receive(:size).with('/opt/test-venv/bin/python').and_return(150)
        allow(File).to receive(:size).with('/opt/test-venv/bin/activate').and_return(0)
      end

      it 'returns false and logs warning' do
        expect(Puppet).to receive(:warning).with(/Invalid venv detected at \/opt\/test-venv: python size=150, activate size=0/)
        expect(provider.send(:venv_files_valid?)).to be false
      end
    end

    context 'when both files have zero size' do
      before(:each) do
        allow(File).to receive(:exist?).with('/opt/test-venv/bin/python').and_return(true)
        allow(File).to receive(:exist?).with('/opt/test-venv/bin/activate').and_return(true)
        allow(File).to receive(:size).with('/opt/test-venv/bin/python').and_return(0)
        allow(File).to receive(:size).with('/opt/test-venv/bin/activate').and_return(0)
      end

      it 'returns false and logs warning' do
        expect(Puppet).to receive(:warning).with(/Invalid venv detected at \/opt\/test-venv: python size=0, activate size=0/)
        expect(provider.send(:venv_files_valid?)).to be false
      end
    end
  end

  describe '#create' do
    before(:each) do
      allow(provider).to receive(:execute)
      allow(provider).to receive(:create_venv)
      allow(provider).to receive(:sync_requirements)
      allow(provider).to receive(:requirements?).and_return(true)
    end

    it 'creates the virtual environment with correct parameters' do
      expect(provider).to receive(:create_venv)
      expect(provider).to receive(:sync_requirements)

      provider.create
    end

    context 'with system site packages enabled' do
      before(:each) do
        resource[:system_site_packages] = true
      end

      it 'includes --system-site-packages flag' do
        expect(provider).to receive(:create_venv)
        expect(provider).to receive(:sync_requirements)

        provider.create
      end
    end

    context 'when venv creation fails' do
      before(:each) do
        allow(provider).to receive(:create_venv).and_raise(Puppet::Error, 'Failed to create virtual environment')
      end

      it 'raises a Puppet::Error' do
        expect { provider.create }.to raise_error(Puppet::Error, %r{Failed to create virtual environment})
      end
    end

    context 'when venv appears created but is not functional' do
      before(:each) do
        allow(provider).to receive(:create_venv).and_call_original
        allow(provider).to receive(:execute)
        allow(provider).to receive(:exists?).and_return(false)
      end

      it 'raises a Puppet::Error' do
        expect { provider.send(:create_venv) }.to raise_error(Puppet::Error, %r{appeared to succeed but.*is not functional})
      end
    end
  end

  describe '#create_venv' do
    before(:each) do
      allow(provider).to receive(:execute)
      allow(File).to receive(:directory?).with('/opt/test-venv').and_return(true)
      allow(File).to receive(:executable?).with('/opt/test-venv/bin/python').and_return(true)
      allow(File).to receive(:executable?).with('/opt/test-venv/bin/pip').and_return(true)
      allow(File).to receive(:exist?).with('/opt/test-venv/bin/python').and_return(true)
      allow(File).to receive(:exist?).with('/opt/test-venv/bin/activate').and_return(true)
      allow(File).to receive(:size).with('/opt/test-venv/bin/python').and_return(100)
      allow(File).to receive(:size).with('/opt/test-venv/bin/activate').and_return(200)
      allow(provider).to receive(:upgrade_pip)
    end

    it 'creates venv with correct command' do
      expect(provider).to receive(:execute).with(
        ['/usr/bin/python3', '-m', 'venv', '/opt/test-venv'],
        hash_including(failonfail: true, combine: true),
      )

      provider.send(:create_venv)
    end

    context 'with system site packages enabled' do
      before(:each) do
        resource[:system_site_packages] = true
      end

      it 'includes --system-site-packages flag' do
        expect(provider).to receive(:execute).with(
          ['/usr/bin/python3', '-m', 'venv', '--system-site-packages', '/opt/test-venv'],
          hash_including(failonfail: true, combine: true),
        )

        provider.send(:create_venv)
      end
    end

    context 'when venv creation produces zero-sized files' do
      before(:each) do
        allow(File).to receive(:directory?).with('/opt/test-venv').and_return(true)
        allow(File).to receive(:executable?).with('/opt/test-venv/bin/python').and_return(true)
        allow(File).to receive(:executable?).with('/opt/test-venv/bin/pip').and_return(true)
        allow(File).to receive(:exist?).with('/opt/test-venv/bin/python').and_return(true)
        allow(File).to receive(:exist?).with('/opt/test-venv/bin/activate').and_return(true)
        allow(File).to receive(:size).with('/opt/test-venv/bin/python').and_return(0)
        allow(File).to receive(:size).with('/opt/test-venv/bin/activate').and_return(0)
        allow(File).to receive(:exist?).with('/opt/test-venv').and_return(true)
      end

      it 'logs error, cleans up, and raises Puppet::Error' do
        expect(Puppet).to receive(:warning).with(%r{Invalid venv detected})
        expect(Puppet).to receive(:err).with(%r{Python venv creation failed.*contains invalid zero-sized files})
        expect(Puppet::FileSystem).to receive(:rmtree).with('/opt/test-venv')

        expect { provider.send(:create_venv) }.to raise_error(
          Puppet::Error,
          %r{Failed to create valid virtual environment.*venv files are zero-sized}
        )
      end
    end

    context 'when only python file is zero-sized' do
      before(:each) do
        allow(File).to receive(:directory?).with('/opt/test-venv').and_return(true)
        allow(File).to receive(:executable?).with('/opt/test-venv/bin/python').and_return(true)
        allow(File).to receive(:executable?).with('/opt/test-venv/bin/pip').and_return(true)
        allow(File).to receive(:exist?).with('/opt/test-venv/bin/python').and_return(true)
        allow(File).to receive(:exist?).with('/opt/test-venv/bin/activate').and_return(true)
        allow(File).to receive(:size).with('/opt/test-venv/bin/python').and_return(0)
        allow(File).to receive(:size).with('/opt/test-venv/bin/activate').and_return(200)
        allow(File).to receive(:exist?).with('/opt/test-venv').and_return(true)
      end

      it 'detects invalid venv and raises error' do
        expect(Puppet).to receive(:warning).with(%r{Invalid venv detected.*python size=0})
        expect(Puppet).to receive(:err).with(%r{Python venv creation failed})
        expect(Puppet::FileSystem).to receive(:rmtree).with('/opt/test-venv')

        expect { provider.send(:create_venv) }.to raise_error(
          Puppet::Error,
          %r{venv files are zero-sized}
        )
      end
    end

    context 'when only activate file is zero-sized' do
      before(:each) do
        allow(File).to receive(:directory?).with('/opt/test-venv').and_return(true)
        allow(File).to receive(:executable?).with('/opt/test-venv/bin/python').and_return(true)
        allow(File).to receive(:executable?).with('/opt/test-venv/bin/pip').and_return(true)
        allow(File).to receive(:exist?).with('/opt/test-venv/bin/python').and_return(true)
        allow(File).to receive(:exist?).with('/opt/test-venv/bin/activate').and_return(true)
        allow(File).to receive(:size).with('/opt/test-venv/bin/python').and_return(100)
        allow(File).to receive(:size).with('/opt/test-venv/bin/activate').and_return(0)
        allow(File).to receive(:exist?).with('/opt/test-venv').and_return(true)
      end

      it 'detects invalid venv and raises error' do
        expect(Puppet).to receive(:warning).with(%r{Invalid venv detected.*activate size=0})
        expect(Puppet).to receive(:err).with(%r{Python venv creation failed})
        expect(Puppet::FileSystem).to receive(:rmtree).with('/opt/test-venv')

        expect { provider.send(:create_venv) }.to raise_error(
          Puppet::Error,
          %r{venv files are zero-sized}
        )
      end
    end

    context 'when venv files are valid after creation' do
      before(:each) do
        allow(File).to receive(:size).with('/opt/test-venv/bin/python').and_return(150)
        allow(File).to receive(:size).with('/opt/test-venv/bin/activate').and_return(250)
      end

      it 'completes successfully and upgrades pip' do
        expect(provider).to receive(:upgrade_pip)
        expect { provider.send(:create_venv) }.not_to raise_error
      end
    end
  end

  describe '#destroy' do
    context 'when venv exists' do
      before(:each) do
        allow(File).to receive(:exist?).with('/opt/test-venv').and_return(true)
      end

      it 'removes the venv directory' do
        expect(Puppet::FileSystem).to receive(:rmtree).with('/opt/test-venv')
        provider.destroy
      end
    end

    context 'when venv does not exist' do
      before(:each) do
        allow(File).to receive(:exist?).with('/opt/test-venv').and_return(false)
      end

      it 'does not try to remove anything' do
        expect(Puppet::FileSystem).not_to receive(:rmtree)
        provider.destroy
      end
    end
  end

  describe 'private methods' do
    describe '#install_requirements_file' do
      before(:each) do
        allow(provider).to receive(:execute)
      end

      it 'installs requirements with pip args' do
        expect(provider).to receive(:execute).with(
          ['/opt/test-venv/bin/pip', 'install', '-r', '/tmp/requirements.txt', '--no-cache-dir'],
          hash_including(failonfail: true, combine: true),
        )

        provider.send(:install_requirements_file, '/tmp/requirements.txt')
      end

      context 'when pip install fails' do
        before(:each) do
          allow(provider).to receive(:execute).and_raise(Puppet::ExecutionFailure, 'install failed')
        end

        it 'raises Puppet::Error' do
          expect { provider.send(:install_requirements_file, '/tmp/requirements.txt') }.to raise_error(Puppet::Error, %r{Failed to install requirements})
        end
      end
    end

    describe '#file_hash' do
      it 'calculates SHA256 hash of file content' do
        allow(File).to receive(:read).with('/tmp/test.txt').and_return("test content\n")
        hash = provider.send(:file_hash, '/tmp/test.txt')
        expect(hash).to be_a(String)
        expect(hash.length).to eq(64) # SHA256 hex digest length
      end
    end

    describe '#individual_requirements_hash' do
      it 'calculates hash of sorted requirements' do
        hash = provider.send(:individual_requirements_hash)
        expect(hash).to be_a(String)
        expect(hash.length).to eq(64)
      end

      it 'produces different hash when requirements change' do
        old_hash = provider.send(:individual_requirements_hash)
        resource[:requirements] = ['new-package==1.0.0']
        new_hash = provider.send(:individual_requirements_hash)
        expect(old_hash).not_to eq(new_hash)
      end
    end

    describe '#get_pip_freeze_hash' do
      context 'when venv exists' do
        before(:each) do
          allow(provider).to receive(:exists?).and_return(true)
          allow(provider).to receive(:execute).with(
            ['/opt/test-venv/bin/pip', 'freeze', '-l'],
            hash_including(failonfail: true),
          ).and_return("flask==2.2.2\nrequests==2.28.1\n")
        end

        it 'returns SHA256 hash of pip freeze output' do
          hash = provider.send(:get_pip_freeze_hash)
          expect(hash).to be_a(String)
          expect(hash.length).to eq(64) # SHA256 hex digest length
        end

        it 'hash changes when installed packages change' do
          old_hash = provider.send(:get_pip_freeze_hash)

          # Change pip freeze output
          allow(provider).to receive(:execute).with(
            ['/opt/test-venv/bin/pip', 'freeze', '-l'],
            hash_including(failonfail: true),
          ).and_return("flask==2.3.0\nrequests==2.28.1\n")

          new_hash = provider.send(:get_pip_freeze_hash)
          expect(old_hash).not_to eq(new_hash)
        end
      end

      context 'when venv does not exist' do
        before(:each) do
          allow(provider).to receive(:exists?).and_return(false)
        end

        it 'returns nil' do
          expect(provider.send(:get_pip_freeze_hash)).to be_nil
        end
      end

      context 'when pip freeze fails' do
        before(:each) do
          allow(provider).to receive(:exists?).and_return(true)
          allow(provider).to receive(:execute).and_raise(Puppet::ExecutionFailure, 'pip failed')
        end

        it 'logs warning and returns nil' do
          expect(Puppet).to receive(:warning).with(%r{Failed to run pip freeze})
          expect(provider.send(:get_pip_freeze_hash)).to be_nil
        end
      end
    end
  end

  describe 'helper methods' do
    it 'returns correct python command' do
      expect(provider.python_cmd).to eq('/usr/bin/python3')
    end

    it 'returns correct venv path' do
      expect(provider.venv_path).to eq('/opt/test-venv')
    end

    it 'returns correct pip path' do
      expect(provider.pip_path).to eq('/opt/test-venv/bin/pip')
    end

    it 'returns correct python venv path' do
      expect(provider.python_venv_path).to eq('/opt/test-venv/bin/python')
    end

    it 'returns correct activate path' do
      expect(provider.activate_path).to eq('/opt/test-venv/bin/activate')
    end
  end

  describe 'when state file is missing' do
    let(:venv_exists_resource) do
      Puppet::Type.type(:python_venv).new(
        path: '/opt/existing-venv',
        requirements: ['requests==2.28.1'],
      )
    end

    let(:venv_exists_provider) { described_class.new(venv_exists_resource) }

    before(:each) do
      # Mock that venv exists
      allow(venv_exists_provider).to receive(:exists?).and_return(true)
      allow(venv_exists_provider).to receive(:exists?).and_return(true)

      # Mock that state file does NOT exist (important!)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/opt/existing-venv/.requirements_state').and_return(false)

      # Mock file operations for individual requirements
      allow(File).to receive(:write)
      allow(File).to receive(:read).and_call_original

      # Mock execute for pip install
      allow(venv_exists_provider).to receive(:execute).and_return('')
      allow(venv_exists_provider).to receive(:get_pip_freeze_hash).and_return('newhash123')

      # Mock individual_requirements_hash
      allow(venv_exists_provider).to receive(:individual_requirements_hash).and_return('reqhash456')
    end

    it 'triggers full reinstallation when state file is missing' do
      expect(Puppet).to receive(:info).with(%r{Installing requirements \(initial setup\)}).ordered
      expect(Puppet).to receive(:info).with(%r{Requirements synchronized successfully}).ordered

      # Allow other info calls
      allow(Puppet).to receive(:info)
      allow(Puppet).to receive(:debug)

      expect(venv_exists_provider).to receive(:install_requirements_file).with(
        '/opt/existing-venv/.individual_requirements.txt',
      )

      venv_exists_provider.send(:sync_requirements)
    end

    it 'creates state file after reinstallation' do
      expect(File).to receive(:write).with(
        '/opt/existing-venv/.requirements_state',
        anything,
      )

      venv_exists_provider.send(:sync_requirements)
    end
  end

  describe 'when state file is missing' do
    let(:venv_exists_resource) do
      Puppet::Type.type(:python_venv).new(
        path: '/opt/existing-venv',
        requirements: ['requests==2.28.1'],
      )
    end

    let(:venv_exists_provider) { described_class.new(venv_exists_resource) }

    before(:each) do
      # Mock that venv exists
      allow(venv_exists_provider).to receive(:exists?).and_return(true)
      allow(venv_exists_provider).to receive(:exists?).and_return(false)

      # Mock that state file does NOT exist (important!)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/opt/existing-venv/.requirements_state').and_return(false)

      # Mock file operations for individual requirements
      allow(File).to receive(:write)
      allow(File).to receive(:read).and_call_original

      # Mock execute for pip install
      allow(venv_exists_provider).to receive(:execute).and_return('')
      allow(venv_exists_provider).to receive(:get_pip_freeze_hash).and_return('newhash123')

      # Mock individual_requirements_hash
      allow(venv_exists_provider).to receive(:individual_requirements_hash).and_return('reqhash456')

      # Mock exists? method
      allow(provider).to receive(:exists?).and_return(true)
    end

    it 'triggers full reinstallation when state file is missing' do
      expect(Puppet).to receive(:info).with(%r{Installing requirements \(initial setup\)}).ordered
      expect(Puppet).to receive(:info).with(%r{Requirements synchronized successfully}).ordered

      # Allow other info calls
      allow(Puppet).to receive(:info)
      allow(Puppet).to receive(:debug)

      expect(venv_exists_provider).to receive(:install_requirements_file).with(
        '/opt/existing-venv/.individual_requirements.txt',
      )

      venv_exists_provider.send(:sync_requirements)
    end

    it 'creates state file after reinstallation' do
      expect(File).to receive(:write).with(
        '/opt/existing-venv/.requirements_state',
        anything,
      )

      venv_exists_provider.send(:sync_requirements)
    end
  end

  describe 'when pip freeze hash is poisoned by manual pip install' do
    let(:poisoned_venv_resource) do
      Puppet::Type.type(:python_venv).new(
        path: '/opt/poisoned-venv',
        requirements: ['requests==2.28.1', 'flask==2.2.2'],
      )
    end

    let(:poisoned_venv_provider) { described_class.new(poisoned_venv_resource) }

    before(:each) do
      # Mock that venv exists
      allow(poisoned_venv_provider).to receive(:exists?).and_return(true)

      # Mock that state file EXISTS with original pip freeze hash
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/opt/poisoned-venv/.requirements_state').and_return(true)

      # Original state that was saved after initial sync
      original_state = {
        'individual_requirements' => 'original_req_hash_123',
        'pip_freeze_hash' => 'original_freeze_abc'
      }

      # Mock loading the original state
      allow(File).to receive(:read).with('/opt/poisoned-venv/.requirements_state').and_return(JSON.pretty_generate(original_state))

      # Mock that individual requirements hash hasn't changed
      allow(poisoned_venv_provider).to receive(:individual_requirements_hash).and_return('original_req_hash_123')

      # Mock that pip freeze hash HAS changed (someone manually installed packages)
      # First call returns the poisoned hash, subsequent calls return new hash after reinstall
      call_count = 0
      allow(poisoned_venv_provider).to receive(:get_pip_freeze_hash) do
        call_count += 1
        if call_count == 1
          'poisoned_freeze_xyz' # Different from original_freeze_abc
        else
          'new_freeze_after_reinstall_def' # Hash after we reinstall
        end
      end

      # Mock file operations
      allow(File).to receive(:write)

      # Mock execute for pip install
      allow(poisoned_venv_provider).to receive(:execute).and_return('')
    end

    it 'detects pip freeze hash mismatch' do
      in_sync = poisoned_venv_provider.requirements_in_sync?
      expect(in_sync).to be false
    end

    it 'logs that installed packages were modified externally' do
      expect(Puppet).to receive(:info).with(%r{Changes detected - reinstalling requirements}).ordered
      expect(Puppet).to receive(:info).with(%r{Installed packages modified externally}).ordered
      expect(Puppet).to receive(:info).with(%r{Requirements synchronized successfully}).ordered

      # Allow other info/debug calls
      allow(Puppet).to receive(:info)
      allow(Puppet).to receive(:debug)

      poisoned_venv_provider.send(:sync_requirements)
    end

    it 'triggers reinstallation with force flag' do
      # Allow logging
      allow(Puppet).to receive(:info)
      allow(Puppet).to receive(:debug)

      expect(poisoned_venv_provider).to receive(:install_requirements_file).with(
        '/opt/poisoned-venv/.individual_requirements.txt',
      )

      poisoned_venv_provider.send(:sync_requirements)
    end

    it 'saves new pip freeze hash to state file after reinstall' do
      # Allow logging
      allow(Puppet).to receive(:info)
      allow(Puppet).to receive(:debug)

      # Expect state file to be written with new pip freeze hash
      expect(File).to receive(:write).with(
        '/opt/poisoned-venv/.requirements_state',
        %r{new_freeze_after_reinstall_def},
      )

      poisoned_venv_provider.send(:sync_requirements)
    end

    it 'includes both individual requirements hash and new pip freeze hash in saved state' do
      # Allow logging
      allow(Puppet).to receive(:info)
      allow(Puppet).to receive(:debug)

      # Capture what gets written to the state file
      written_state = nil
      allow(File).to receive(:write).with(
        '/opt/poisoned-venv/.requirements_state',
        anything,
      ) do |_path, content|
        written_state = JSON.parse(content)
      end

      poisoned_venv_provider.send(:sync_requirements)

      expect(written_state).to include(
        'individual_requirements' => 'original_req_hash_123',
        'pip_freeze_hash' => 'new_freeze_after_reinstall_def',
      )
    end
  end
end
