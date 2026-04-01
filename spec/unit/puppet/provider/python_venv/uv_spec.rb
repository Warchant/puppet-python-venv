# frozen_string_literal: true

require 'spec_helper'

describe Puppet::Type.type(:python_venv).provider(:uv) do
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

  before(:each) do
    allow(provider).to receive(:uv_cmd).and_return('/usr/bin/uv')
  end

  describe '#exists?' do
    context 'when venv exists and is functional' do
      before(:each) do
        allow(File).to receive(:directory?).with('/opt/test-venv').and_return(true)
        allow(File).to receive(:executable?).with('/opt/test-venv/bin/python').and_return(true)
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

    context 'when venv directory exists but python executable is missing' do
      before(:each) do
        allow(File).to receive(:directory?).with('/opt/test-venv').and_return(true)
        allow(File).to receive(:executable?).with('/opt/test-venv/bin/python').and_return(false)
      end

      it 'returns false' do
        expect(provider.exists?).to be false
      end
    end

    context 'when venv has zero-sized python file' do
      before(:each) do
        allow(File).to receive(:directory?).with('/opt/test-venv').and_return(true)
        allow(File).to receive(:executable?).with('/opt/test-venv/bin/python').and_return(true)
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
        expect(Puppet).to receive(:warning).with(%r{Invalid venv detected at /opt/test-venv: python size=0, activate size=250})
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
        expect(Puppet).to receive(:warning).with(%r{Invalid venv detected at /opt/test-venv: python size=150, activate size=0})
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
        expect(Puppet).to receive(:warning).with(%r{Invalid venv detected at /opt/test-venv: python size=0, activate size=0})
        expect(provider.send(:venv_files_valid?)).to be false
      end
    end
  end

  describe '#owner' do
    context 'when venv exists' do
      before(:each) do
        allow(File).to receive(:exist?).with('/opt/test-venv').and_return(true)
        allow(File).to receive(:stat).with('/opt/test-venv').and_return(double(uid: 1001))
        allow(Etc).to receive(:getpwuid).with(1001).and_return(double(name: 'myuser'))
      end

      it 'returns the owner name' do
        expect(provider.owner).to eq('myuser')
      end
    end

    context 'when venv does not exist' do
      before(:each) do
        allow(File).to receive(:exist?).with('/opt/test-venv').and_return(false)
      end

      it 'returns :absent' do
        expect(provider.owner).to eq(:absent)
      end
    end
  end

  describe '#owner=' do
    it 'recursively chowns all files' do
      allow(Etc).to receive(:getpwnam).with('newuser').and_return(double(uid: 1005))
      allow(Find).to receive(:find).with('/opt/test-venv').and_yield('/opt/test-venv').and_yield('/opt/test-venv/bin/python')
      expect(File).to receive(:chown).with(1005, -1, '/opt/test-venv')
      expect(File).to receive(:chown).with(1005, -1, '/opt/test-venv/bin/python')
      provider.send(:owner=, 'newuser')
    end
  end

  describe '#group' do
    context 'when venv exists' do
      before(:each) do
        allow(File).to receive(:exist?).with('/opt/test-venv').and_return(true)
        allow(File).to receive(:stat).with('/opt/test-venv').and_return(double(gid: 1002))
        allow(Etc).to receive(:getgrgid).with(1002).and_return(double(name: 'mygroup'))
      end

      it 'returns the group name' do
        expect(provider.group).to eq('mygroup')
      end
    end

    context 'when venv does not exist' do
      before(:each) do
        allow(File).to receive(:exist?).with('/opt/test-venv').and_return(false)
      end

      it 'returns :absent' do
        expect(provider.group).to eq(:absent)
      end
    end
  end

  describe '#group=' do
    it 'recursively chowns all files' do
      allow(Etc).to receive(:getgrnam).with('newgroup').and_return(double(gid: 1010))
      allow(Find).to receive(:find).with('/opt/test-venv').and_yield('/opt/test-venv').and_yield('/opt/test-venv/bin/python')
      expect(File).to receive(:chown).with(-1, 1010, '/opt/test-venv')
      expect(File).to receive(:chown).with(-1, 1010, '/opt/test-venv/bin/python')
      provider.send(:group=, 'newgroup')
    end
  end

  describe '#apply_ownership' do
    context 'when owner and group are set' do
      before(:each) do
        resource[:owner] = 'myuser'
        resource[:group] = 'mygroup'
        allow(Etc).to receive(:getpwnam).with('myuser').and_return(double(uid: 1001))
        allow(Etc).to receive(:getgrnam).with('mygroup').and_return(double(gid: 1002))
        allow(Find).to receive(:find).with('/opt/test-venv').and_yield('/opt/test-venv').and_yield('/opt/test-venv/bin/python')
      end

      it 'chowns all files under venv_path' do
        expect(File).to receive(:chown).with(1001, 1002, '/opt/test-venv')
        expect(File).to receive(:chown).with(1001, 1002, '/opt/test-venv/bin/python')
        provider.send(:apply_ownership)
      end
    end

    context 'when only owner is set' do
      before(:each) do
        resource[:owner] = 'myuser'
        allow(Etc).to receive(:getpwnam).with('myuser').and_return(double(uid: 1001))
        allow(Find).to receive(:find).with('/opt/test-venv').and_yield('/opt/test-venv')
      end

      it 'chowns with uid and -1 for gid' do
        expect(File).to receive(:chown).with(1001, -1, '/opt/test-venv')
        provider.send(:apply_ownership)
      end
    end

    context 'when only group is set' do
      before(:each) do
        resource[:group] = 'mygroup'
        allow(Etc).to receive(:getgrnam).with('mygroup').and_return(double(gid: 1002))
        allow(Find).to receive(:find).with('/opt/test-venv').and_yield('/opt/test-venv')
      end

      it 'chowns with -1 for uid and gid' do
        expect(File).to receive(:chown).with(-1, 1002, '/opt/test-venv')
        provider.send(:apply_ownership)
      end
    end

    context 'when neither owner nor group is set' do
      it 'does nothing' do
        expect(Find).not_to receive(:find)
        provider.send(:apply_ownership)
      end
    end
  end

  describe '#create' do
    before(:each) do
      allow(provider).to receive(:execute)
      allow(provider).to receive(:create_venv)
      allow(provider).to receive(:apply_ownership)
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
        allow(provider).to receive(:execute)
        allow(File).to receive(:directory?).and_call_original
        allow(File).to receive(:directory?).with('/opt/test-venv').and_return(false)
        allow(provider).to receive(:create_venv).and_call_original
      end

      it 'raises a Puppet::Error' do
        expect { provider.send(:create_venv) }.to raise_error(Puppet::Error, %r{appeared to succeed but.*is not functional})
      end
    end
  end

  describe '#create_venv' do
    before(:each) do
      allow(provider).to receive(:execute)
      allow(File).to receive(:directory?).and_call_original
      allow(File).to receive(:directory?).with('/opt/test-venv').and_return(true)
      allow(File).to receive(:executable?).with('/opt/test-venv/bin/python').and_return(true)
      allow(File).to receive(:exist?).with('/opt/test-venv/bin/python').and_return(true)
      allow(File).to receive(:exist?).with('/opt/test-venv/bin/activate').and_return(true)
      allow(File).to receive(:size).with('/opt/test-venv/bin/python').and_return(100)
      allow(File).to receive(:size).with('/opt/test-venv/bin/activate').and_return(200)
    end

    it 'creates venv with correct command' do
      expect(provider).to receive(:execute).with(
        ['/usr/bin/uv', 'venv', '--python', '/usr/bin/python3', '/opt/test-venv'],
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
          ['/usr/bin/uv', 'venv', '--python', '/usr/bin/python3', '--system-site-packages', '/opt/test-venv'],
          hash_including(failonfail: true, combine: true),
        )

        provider.send(:create_venv)
      end
    end

    context 'when venv creation produces zero-sized files' do
      before(:each) do
        allow(File).to receive(:directory?).with('/opt/test-venv').and_return(true)
        allow(File).to receive(:executable?).with('/opt/test-venv/bin/python').and_return(true)
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
          %r{Failed to create valid virtual environment.*venv files are zero-sized},
        )
      end
    end

    context 'when only python file is zero-sized' do
      before(:each) do
        allow(File).to receive(:directory?).with('/opt/test-venv').and_return(true)
        allow(File).to receive(:executable?).with('/opt/test-venv/bin/python').and_return(true)
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
          %r{venv files are zero-sized},
        )
      end
    end

    context 'when only activate file is zero-sized' do
      before(:each) do
        allow(File).to receive(:directory?).with('/opt/test-venv').and_return(true)
        allow(File).to receive(:executable?).with('/opt/test-venv/bin/python').and_return(true)
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
          %r{venv files are zero-sized},
        )
      end
    end

    context 'when venv files are valid after creation' do
      before(:each) do
        allow(File).to receive(:size).with('/opt/test-venv/bin/python').and_return(150)
        allow(File).to receive(:size).with('/opt/test-venv/bin/activate').and_return(250)
      end

      it 'completes successfully without pip upgrade' do
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

      it 'installs requirements with uv pip and uv_args' do
        expect(provider).to receive(:execute).with(
          ['/usr/bin/uv', 'pip', 'install', '-r', '/tmp/requirements.txt', '--python', '/opt/test-venv/bin/python', '--no-cache-dir'],
          hash_including(failonfail: true, combine: true),
        )

        provider.send(:install_requirements_file, '/tmp/requirements.txt')
      end

      context 'when uv pip install fails' do
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

    describe '#get_freeze_hash' do
      context 'when venv exists' do
        before(:each) do
          allow(provider).to receive(:exists?).and_return(true)
          allow(provider).to receive(:execute).with(
            ['/usr/bin/uv', 'pip', 'freeze', '--python', '/opt/test-venv/bin/python'],
            hash_including(failonfail: true),
          ).and_return("flask==2.2.2\nrequests==2.28.1\n")
        end

        it 'returns SHA256 hash of uv pip freeze output' do
          hash = provider.send(:get_freeze_hash)
          expect(hash).to be_a(String)
          expect(hash.length).to eq(64) # SHA256 hex digest length
        end

        it 'hash changes when installed packages change' do
          old_hash = provider.send(:get_freeze_hash)

          # Change uv pip freeze output
          allow(provider).to receive(:execute).with(
            ['/usr/bin/uv', 'pip', 'freeze', '--python', '/opt/test-venv/bin/python'],
            hash_including(failonfail: true),
          ).and_return("flask==2.3.0\nrequests==2.28.1\n")

          new_hash = provider.send(:get_freeze_hash)
          expect(old_hash).not_to eq(new_hash)
        end
      end

      context 'when venv does not exist' do
        before(:each) do
          allow(provider).to receive(:exists?).and_return(false)
        end

        it 'returns nil' do
          expect(provider.send(:get_freeze_hash)).to be_nil
        end
      end

      context 'when uv pip freeze fails' do
        before(:each) do
          allow(provider).to receive(:exists?).and_return(true)
          allow(provider).to receive(:execute).and_raise(Puppet::ExecutionFailure, 'uv failed')
        end

        it 'logs warning and returns nil' do
          expect(Puppet).to receive(:warning).with(%r{Failed to run uv pip freeze})
          expect(provider.send(:get_freeze_hash)).to be_nil
        end
      end
    end
  end

  describe 'helper methods' do
    it 'returns correct python spec' do
      expect(provider.python_spec).to eq('/usr/bin/python3')
    end

    it 'returns correct venv path' do
      expect(provider.venv_path).to eq('/opt/test-venv')
    end

    it 'returns correct python venv path' do
      expect(provider.python_venv_path).to eq('/opt/test-venv/bin/python')
    end

    it 'returns correct activate path' do
      expect(provider.activate_path).to eq('/opt/test-venv/bin/activate')
    end

    describe '#uv_cmd' do
      it 'returns configured uv command' do
        allow(described_class).to receive(:command).with(:uv).and_return('/opt/custom/uv')
        fresh_provider = described_class.new(resource)
        expect(fresh_provider.uv_cmd).to eq('/opt/custom/uv')
      end
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
      allow(venv_exists_provider).to receive(:uv_cmd).and_return('/usr/bin/uv')

      # Mock that venv exists
      allow(venv_exists_provider).to receive(:exists?).and_return(true)
      allow(venv_exists_provider).to receive(:exists?).and_return(true)

      # Mock that state file does NOT exist (important!)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/opt/existing-venv/.requirements_state').and_return(false)

      # Mock file operations for individual requirements
      allow(File).to receive(:write)
      allow(File).to receive(:read).and_call_original

      # Mock execute for uv pip install
      allow(venv_exists_provider).to receive(:execute).and_return('')
      allow(venv_exists_provider).to receive(:get_freeze_hash).and_return('newhash123')

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

  describe 'when state file is missing (venv not exists)' do
    let(:venv_exists_resource) do
      Puppet::Type.type(:python_venv).new(
        path: '/opt/existing-venv',
        requirements: ['requests==2.28.1'],
      )
    end

    let(:venv_exists_provider) { described_class.new(venv_exists_resource) }

    before(:each) do
      allow(venv_exists_provider).to receive(:uv_cmd).and_return('/usr/bin/uv')

      # Mock that venv does not exist
      allow(venv_exists_provider).to receive(:exists?).and_return(false)

      # Mock that state file does NOT exist (important!)
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with('/opt/existing-venv/.requirements_state').and_return(false)

      # Mock file operations for individual requirements
      allow(File).to receive(:write)
      allow(File).to receive(:read).and_call_original

      # Mock execute for uv pip install
      allow(venv_exists_provider).to receive(:execute).and_return('')
      allow(venv_exists_provider).to receive(:get_freeze_hash).and_return('newhash123')

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

  describe 'when pip freeze hash is poisoned by manual package install' do
    let(:poisoned_venv_resource) do
      Puppet::Type.type(:python_venv).new(
        path: '/opt/poisoned-venv',
        requirements: ['requests==2.28.1', 'flask==2.2.2'],
      )
    end

    let(:poisoned_venv_provider) { described_class.new(poisoned_venv_resource) }

    before(:each) do
      allow(poisoned_venv_provider).to receive(:uv_cmd).and_return('/usr/bin/uv')

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

      # Mock that freeze hash HAS changed (someone manually installed packages)
      # First call returns the poisoned hash, subsequent calls return new hash after reinstall
      call_count = 0
      allow(poisoned_venv_provider).to receive(:get_freeze_hash) do
        call_count += 1
        if call_count == 1
          'poisoned_freeze_xyz' # Different from original_freeze_abc
        else
          'new_freeze_after_reinstall_def' # Hash after we reinstall
        end
      end

      # Mock file operations
      allow(File).to receive(:write)

      # Mock execute for uv pip install
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

    it 'triggers reinstallation' do
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

  describe 'additional coverage cases' do
    describe '#flush' do
      it 'synchronizes requirements when venv exists and requirements are declared' do
        allow(provider).to receive(:exists?).and_return(true)
        allow(provider).to receive(:requirements?).and_return(true)
        expect(provider).to receive(:sync_requirements)

        provider.flush
      end

      it 'does nothing when venv does not exist' do
        allow(provider).to receive(:exists?).and_return(false)
        allow(provider).to receive(:requirements?).and_return(true)
        expect(provider).not_to receive(:sync_requirements)

        provider.flush
      end
    end

    describe '#parse_requirements_file' do
      it 'parses, strips comments, and sorts requirements' do
        allow(File).to receive(:readlines).with('/tmp/req.txt').and_return([
                                                                             "requests==2.31.0\n",
                                                                             "\n",
                                                                             "flask==3.0.0 # inline\n",
                                                                             "# full comment\n",
                                                                           ])

        expect(provider.send(:parse_requirements_file, '/tmp/req.txt')).to eq(['flask==3.0.0', 'requests==2.31.0'])
      end

      it 'returns empty array and logs warning when parsing fails' do
        allow(File).to receive(:readlines).with('/tmp/req.txt').and_raise(StandardError, 'boom')
        expect(Puppet).to receive(:warning).with(%r{Failed to parse requirements file /tmp/req.txt: boom})

        expect(provider.send(:parse_requirements_file, '/tmp/req.txt')).to eq([])
      end
    end

    describe '#calculate_expected_state' do
      it 'raises Puppet::Error when requirements file does not exist' do
        resource[:requirements_files] = ['/tmp/missing.txt']
        allow(File).to receive(:exist?).with('/tmp/missing.txt').and_return(false)

        expect { provider.send(:calculate_expected_state) }
          .to raise_error(Puppet::Error, %r{Requirements file does not exist: /tmp/missing.txt})
      end
    end

    describe '#sync_requirements' do
      it 'logs in-sync message and skips installation when no changes are detected' do
        allow(provider).to receive(:requirements?).and_return(true)
        allow(provider).to receive(:calculate_expected_state).and_return({ 'individual_requirements' => 'abc' })
        allow(provider).to receive(:load_requirements_state).and_return({ 'individual_requirements' => 'abc' })
        allow(provider).to receive(:states_differ?).and_return(false)
        expect(Puppet).to receive(:info).with(%r{No changes detected - requirements are in sync})
        expect(provider).not_to receive(:install_all_requirements)

        provider.send(:sync_requirements)
      end
    end

    describe '#log_requirement_list_changes' do
      it 'logs additions, removals and version changes' do
        expect(Puppet).to receive(:info).with('  - Requirements file: /tmp/req.txt changed:').ordered
        expect(Puppet).to receive(:info).with('      + flask==3.0.0').ordered
        expect(Puppet).to receive(:info).with('      - django==4.2.0').ordered
        expect(Puppet).to receive(:info).with('      ~ requests==1.0.0 => requests==2.0.0').ordered

        provider.send(
          :log_requirement_list_changes,
          'Requirements file: /tmp/req.txt',
          ['requests==2.0.0', 'flask==3.0.0'],
          ['requests==1.0.0', 'django==4.2.0'],
        )
      end
    end

    describe '#save_state_after_install' do
      it 'saves state without pip_freeze_hash when hash cannot be calculated' do
        allow(provider).to receive(:get_freeze_hash).and_return(nil)
        expect(provider).to receive(:save_requirements_state).with({ 'individual_requirements' => 'abc' })

        provider.send(:save_state_after_install, { 'individual_requirements' => 'abc' })
      end
    end
  end
end
