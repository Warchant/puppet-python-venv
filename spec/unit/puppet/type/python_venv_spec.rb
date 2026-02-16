# frozen_string_literal: true

require 'spec_helper'

describe Puppet::Type.type(:python_venv) do
  let(:catalog) { Puppet::Resource::Catalog.new }
  let(:type) { described_class }

  describe 'when validating parameters' do
    it 'has a name parameter' do
      expect(type.attrtype(:path)).to eq(:param)
    end

    it 'has an ensure property' do
      expect(type.attrtype(:ensure)).to eq(:property)
    end

    it 'has a python_executable parameter' do
      expect(type.attrtype(:python_executable)).to eq(:param)
    end

    it 'has a system_site_packages parameter' do
      expect(type.attrtype(:system_site_packages)).to eq(:param)
    end

    it 'has a requirements parameter' do
      expect(type.attrtype(:requirements)).to eq(:param)
    end

    it 'has a requirements_files parameter' do
      expect(type.attrtype(:requirements_files)).to eq(:param)
    end

    it 'has a pip_args parameter' do
      expect(type.attrtype(:pip_args)).to eq(:param)
    end
  end

  describe 'when validating parameter values' do
    context 'path parameter' do
      it 'accepts absolute paths' do
        expect { type.new(path: '/opt/venv') }.not_to raise_error
      end

      it 'rejects relative paths' do
        expect { type.new(path: 'relative/path') }.to raise_error(Puppet::Error, %r{Path must be absolute})
      end
    end

    context 'python_executable parameter' do
      it 'accepts valid executable paths' do
        expect { type.new(path: '/opt/venv', python_executable: '/usr/bin/python3') }.not_to raise_error
      end

      it 'rejects empty strings' do
        expect { type.new(path: '/opt/venv', python_executable: '') }.to raise_error(Puppet::Error, %r{must be a non-empty string})
      end

      it 'has a default value' do
        resource = type.new(path: '/opt/venv')
        expect(resource[:python_executable]).to eq('python3')
      end
    end

    context 'system_site_packages parameter' do
      it 'accepts true' do
        expect { type.new(path: '/opt/venv', system_site_packages: true) }.not_to raise_error
      end

      it 'accepts false' do
        expect { type.new(path: '/opt/venv', system_site_packages: false) }.not_to raise_error
      end

      it 'accepts string "true"' do
        resource = type.new(path: '/opt/venv', system_site_packages: 'true')
        expect(resource[:system_site_packages]).to be true
      end

      it 'accepts string "false"' do
        resource = type.new(path: '/opt/venv', system_site_packages: 'false')
        expect(resource[:system_site_packages]).to be false
      end

      it 'has a default value of false' do
        resource = type.new(path: '/opt/venv')
        expect(resource[:system_site_packages]).to be false
      end

      it 'rejects invalid values' do
        expect { type.new(path: '/opt/venv', system_site_packages: 'maybe') }
          .to raise_error(Puppet::ResourceError, %r{Invalid value "maybe"})
      end
    end

    context 'requirements parameter' do
      it 'accepts an array of strings' do
        expect { type.new(path: '/opt/venv', requirements: ['package1==1.0', 'package2']) }.not_to raise_error
      end

      it 'rejects non-arrays' do
        expect { type.new(path: '/opt/venv', requirements: 'package1') }.to raise_error(Puppet::Error, %r{must be an array})
      end

      it 'rejects arrays with non-string elements' do
        expect { type.new(path: '/opt/venv', requirements: ['package1', 123]) }.to raise_error(Puppet::Error, %r{must be a non-empty string})
      end

      it 'rejects arrays with empty strings' do
        expect { type.new(path: '/opt/venv', requirements: ['package1', '']) }.to raise_error(Puppet::Error, %r{must be a non-empty string})
      end

      it 'has a default empty array' do
        resource = type.new(path: '/opt/venv')
        expect(resource[:requirements]).to eq([])
      end
    end

    context 'requirements_files parameter' do
      it 'accepts an array of absolute paths' do
        expect { type.new(path: '/opt/venv', requirements_files: ['/opt/requirements.txt']) }.not_to raise_error
      end

      it 'rejects non-arrays' do
        expect { type.new(path: '/opt/venv', requirements_files: '/opt/requirements.txt') }.to raise_error(Puppet::Error, %r{must be an array})
      end

      it 'rejects relative paths' do
        expect { type.new(path: '/opt/venv', requirements_files: ['requirements.txt']) }.to raise_error(Puppet::Error, %r{must be an absolute path})
      end

      it 'has a default empty array' do
        resource = type.new(path: '/opt/venv')
        expect(resource[:requirements_files]).to eq([])
      end
    end

    context 'pip_args parameter' do
      it 'accepts an array of strings' do
        expect { type.new(path: '/opt/venv', pip_args: ['--no-cache-dir', '--timeout=30']) }.not_to raise_error
      end

      it 'rejects non-arrays' do
        expect { type.new(path: '/opt/venv', pip_args: '--no-cache-dir') }.to raise_error(Puppet::Error, %r{must be an array})
      end

      it 'rejects arrays with non-string elements' do
        expect { type.new(path: '/opt/venv', pip_args: ['--no-cache-dir', 123]) }.to raise_error(Puppet::Error, %r{must be a string})
      end

      it 'has a default empty array' do
        resource = type.new(path: '/opt/venv')
        expect(resource[:pip_args]).to eq([])
      end
    end
  end

  describe 'autorequire behavior' do
    let(:catalog) { Puppet::Resource::Catalog.new }

    before(:each) do
      catalog.add_resource(type.new(
        path: '/opt/venv',
        requirements_files: ['/opt/requirements.txt', '/opt/dev-requirements.txt'],
      ))
    end

    it 'autorequires requirements files' do
      file1 = Puppet::Type.type(:file).new(path: '/opt/requirements.txt')
      file2 = Puppet::Type.type(:file).new(path: '/opt/dev-requirements.txt')
      catalog.add_resource(file1)
      catalog.add_resource(file2)

      rel = catalog.relationship_graph.edges_between(file1, catalog.resource(:python_venv, '/opt/venv'))[0]
      expect(rel).to be_a(Puppet::Relationship)
      expect(rel.event).to eq(:NONE)

      rel2 = catalog.relationship_graph.edges_between(file2, catalog.resource(:python_venv, '/opt/venv'))[0]
      expect(rel2).to be_a(Puppet::Relationship)
      expect(rel2.event).to eq(:NONE)
    end
  end

  describe 'resource creation' do
    it 'creates a valid resource with minimal parameters' do
      resource = type.new(path: '/opt/venv')
      expect(resource[:path]).to eq('/opt/venv')
      expect(resource[:ensure]).to eq(:present)
    end

    it 'creates a valid resource with all parameters' do
      resource = type.new(
        path: '/opt/venv',
        ensure: :present,
        python_executable: '/usr/bin/python3.9',
        system_site_packages: true,
        requirements: ['requests==2.28.1'],
        requirements_files: ['/opt/requirements.txt'],
        pip_args: ['--no-cache-dir'],
      )

      expect(resource[:path]).to eq('/opt/venv')
      expect(resource[:ensure]).to eq(:present)
      expect(resource[:python_executable]).to eq('/usr/bin/python3.9')
      expect(resource[:system_site_packages]).to be true
      expect(resource[:requirements]).to eq(['requests==2.28.1'])
      expect(resource[:requirements_files]).to eq(['/opt/requirements.txt'])
      expect(resource[:pip_args]).to eq(['--no-cache-dir'])
    end
  end

  describe 'requirements_state property' do
    it 'retrieves :insync when provider reports in-sync requirements' do
      resource = type.new(path: '/opt/venv')
      provider = instance_double('provider', requirements_in_sync?: true)
      allow(resource).to receive(:provider).and_return(provider)

      expect(resource.property(:requirements_state).retrieve).to eq(:insync)
    end

    it 'retrieves :out_of_sync when provider reports out-of-sync requirements' do
      resource = type.new(path: '/opt/venv')
      provider = instance_double('provider', requirements_in_sync?: false)
      allow(resource).to receive(:provider).and_return(provider)

      expect(resource.property(:requirements_state).retrieve).to eq(:out_of_sync)
    end

    it 'insync? returns true only for :insync and sync returns :insync' do
      resource = type.new(path: '/opt/venv')
      property = resource.property(:requirements_state)

      expect(property.insync?(:insync)).to be true
      expect(property.insync?(:out_of_sync)).to be false
      expect(property.sync).to eq(:insync)
    end
  end
end
