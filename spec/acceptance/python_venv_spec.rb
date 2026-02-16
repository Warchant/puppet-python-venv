# frozen_string_literal: true

require 'spec_helper_acceptance'

describe 'python_venv resource' do
  let(:venv_path) { '/tmp/test_venv' }
  let(:requirements_file) { '/tmp/test_requirements.txt' }

  before(:each) do
    # Clean up any existing test venv
    shell("rm -rf #{venv_path}")
    shell("rm -f #{requirements_file}")
  end

  after(:each) do
    # Clean up after tests
    shell("rm -rf #{venv_path}")
    shell("rm -f #{requirements_file}")
  end

  describe 'basic venv creation' do
    let(:manifest) do
      <<-PUPPET
        python_venv { '#{venv_path}':
          ensure => present,
        }
      PUPPET
    end

    it 'creates a virtual environment' do
      apply_manifest(manifest, catch_failures: true)

      # Verify venv was created
      expect(file("#{venv_path}/bin/python")).to be_executable
      expect(file("#{venv_path}/bin/pip")).to be_executable
      expect(file("#{venv_path}/pyvenv.cfg")).to be_file
    end

    it 'is idempotent' do
      apply_manifest(manifest, catch_failures: true)
      apply_manifest(manifest, catch_changes: true)
    end
  end

  describe 'venv with system site packages' do
    let(:manifest) do
      <<-PUPPET
        python_venv { '#{venv_path}':
          ensure               => present,
          system_site_packages => true,
        }
      PUPPET
    end

    it 'creates venv with system site packages access' do
      apply_manifest(manifest, catch_failures: true)

      # Check that pyvenv.cfg contains include-system-site-packages = true
      pyvenv_config = file("#{venv_path}/pyvenv.cfg").content
      expect(pyvenv_config).to match(%r{include-system-site-packages\s*=\s*true}i)
    end
  end

  describe 'venv with individual requirements' do
    let(:manifest) do
      <<-PUPPET
        python_venv { '#{venv_path}':
          ensure       => present,
          requirements => ['six==1.16.0', 'setuptools'],
        }
      PUPPET
    end

    it 'installs the specified packages' do
      apply_manifest(manifest, catch_failures: true)

      # Verify packages are installed
      pip_list = shell("#{venv_path}/bin/pip list --format=json").stdout
      packages = JSON.parse(pip_list)
      package_names = packages.map { |p| p['name'].downcase }

      expect(package_names).to include('six')
      expect(package_names).to include('setuptools')

      # Verify six has the correct version
      six_package = packages.find { |p| p['name'].casecmp('six').zero? }
      expect(six_package['version']).to eq('1.16.0')
    end
  end

  describe 'venv with requirements file' do
    let(:requirements_content) do
      <<-REQUIREMENTS
        six==1.16.0
        setuptools>=40.0
        wheel
      REQUIREMENTS
    end

    let(:manifest) do
      <<-PUPPET
        file { '#{requirements_file}':
          ensure  => present,
          content => '#{requirements_content}',
        }

        python_venv { '#{venv_path}':
          ensure             => present,
          requirements_files => ['#{requirements_file}'],
          require            => File['#{requirements_file}'],
        }
      PUPPET
    end

    it 'installs packages from requirements file' do
      apply_manifest(manifest, catch_failures: true)

      # Verify packages are installed
      pip_list = shell("#{venv_path}/bin/pip list --format=json").stdout
      packages = JSON.parse(pip_list)
      package_names = packages.map { |p| p['name'].downcase }

      expect(package_names).to include('six')
      expect(package_names).to include('setuptools')
      expect(package_names).to include('wheel')
    end
  end

  describe 'venv with both requirements file and individual requirements' do
    let(:requirements_content) do
      <<-REQUIREMENTS
        six==1.16.0
        setuptools
      REQUIREMENTS
    end

    let(:manifest) do
      <<-PUPPET
        file { '#{requirements_file}':
          ensure  => present,
          content => '#{requirements_content}',
        }

        python_venv { '#{venv_path}':
          ensure             => present,
          requirements_files => ['#{requirements_file}'],
          requirements       => ['wheel', 'pip-tools'],
          require            => File['#{requirements_file}'],
        }
      PUPPET
    end

    it 'installs packages from both sources' do
      apply_manifest(manifest, catch_failures: true)

      # Verify packages are installed
      pip_list = shell("#{venv_path}/bin/pip list --format=json").stdout
      packages = JSON.parse(pip_list)
      package_names = packages.map { |p| p['name'].downcase }

      # From requirements file
      expect(package_names).to include('six')
      expect(package_names).to include('setuptools')

      # From individual requirements
      expect(package_names).to include('wheel')
      expect(package_names).to include('pip-tools')
    end
  end

  describe 'venv destruction' do
    let(:create_manifest) do
      <<-PUPPET
        python_venv { '#{venv_path}':
          ensure => present,
        }
      PUPPET
    end

    let(:destroy_manifest) do
      <<-PUPPET
        python_venv { '#{venv_path}':
          ensure => absent,
        }
      PUPPET
    end

    it 'removes the virtual environment' do
      # First create the venv
      apply_manifest(create_manifest, catch_failures: true)
      expect(file(venv_path.to_s)).to be_directory

      # Then destroy it
      apply_manifest(destroy_manifest, catch_failures: true)
      expect(file(venv_path.to_s)).not_to exist
    end
  end

  describe 'error handling' do
    describe 'with non-existent requirements file' do
      let(:manifest) do
        <<-PUPPET
          python_venv { '#{venv_path}':
            ensure             => present,
            requirements_files => ['/non/existent/file.txt'],
          }
        PUPPET
      end

      it 'fails with appropriate error message' do
        apply_manifest(manifest, expect_failures: true) do |result|
          expect(result.stderr).to match(%r{Requirements file does not exist})
        end
      end
    end

    describe 'with invalid python executable' do
      let(:manifest) do
        <<-PUPPET
          python_venv { '#{venv_path}':
            ensure            => present,
            python_executable => '/non/existent/python',
          }
        PUPPET
      end

      it 'fails with appropriate error message' do
        apply_manifest(manifest, expect_failures: true) do |result|
          expect(result.stderr).to match(%r{Failed to create virtual environment})
        end
      end
    end
  end

  describe 'pip args support' do
    let(:manifest) do
      <<-PUPPET
        python_venv { '#{venv_path}':
          ensure       => present,
          requirements => ['six'],
          pip_args     => ['--no-cache-dir', '--quiet'],
        }
      PUPPET
    end

    it 'successfully uses pip args during installation' do
      apply_manifest(manifest, catch_failures: true)

      # Verify the package was still installed despite the extra args
      pip_list = shell("#{venv_path}/bin/pip list --format=json").stdout
      packages = JSON.parse(pip_list)
      package_names = packages.map { |p| p['name'].downcase }

      expect(package_names).to include('six')
    end
  end
end
