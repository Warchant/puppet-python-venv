# frozen_string_literal: true

Puppet::Type.newtype(:python_venv) do
  @doc = <<-DOC
    Manages Python virtual environments with dependency installation.

    This type creates a Python virtual environment and installs specified
    dependencies atomically. It supports both requirements.txt files and
    individual package specifications.

    @example Basic usage
      python_venv { '/opt/myapp/venv':
        ensure             => present,
        python_executable  => '/usr/bin/python3',
        system_site_packages => true,
        requirements       => ['requests==2.28.1', 'flask==2.2.2'],
      }

    @example With requirements.txt
      python_venv { '/opt/myapp/venv':
        ensure             => present,
        requirements_files => ['/opt/myapp/requirements.txt'],
        requirements       => ['additional-package==1.0.0'],
      }
  DOC

  ensurable do
    defaultvalues
    defaultto :present
  end

  newparam(:path, namevar: true) do
    desc 'The path where the virtual environment should be created.'

    validate do |value|
      unless Puppet::Util.absolute_path?(value)
        raise ArgumentError, "Path must be absolute, got: #{value}"
      end
    end
  end

  newparam(:python_executable) do
    desc 'The Python executable to use for creating the virtual environment.'
    defaultto 'python3'

    validate do |value|
      unless value.is_a?(String) && !value.empty?
        raise ArgumentError, "Python executable must be a non-empty string, got: #{value.inspect}"
      end
    end
  end

  newparam(:system_site_packages) do
    desc 'Whether to give the virtual environment access to system site packages.'
    newvalues(:true, :false, true, false)
    defaultto :false

    munge do |value|
      case value
      when :true, 'true', true
        true
      when :false, 'false', false
        false
      else
        raise ArgumentError, "Invalid value for system_site_packages: #{value.inspect}"
      end
    end
  end

  newparam(:requirements) do
    desc 'Array of package specifications to install (e.g., ["requests==2.28.1", "flask"]).'

    validate do |value|
      unless value.is_a?(Array)
        raise ArgumentError, "Requirements must be an array, got: #{value.class}"
      end

      value.each do |req|
        unless req.is_a?(String) && !req.strip.empty?
          raise ArgumentError, "Each requirement must be a non-empty string, got: #{req.inspect}"
        end
      end
    end

    defaultto []
  end

  newparam(:requirements_files) do
    desc 'Array of paths to requirements.txt files to install.'

    validate do |value|
      unless value.is_a?(Array)
        raise ArgumentError, "Requirements files must be an array, got: #{value.class}"
      end

      value.each do |file|
        unless file.is_a?(String) && Puppet::Util.absolute_path?(file)
          raise ArgumentError, "Each requirements file must be an absolute path, got: #{file.inspect}"
        end
      end
    end

    defaultto []
  end

  newparam(:pip_args) do
    desc 'Additional arguments to pass to pip install commands.'

    validate do |value|
      unless value.is_a?(Array)
        raise ArgumentError, "Pip args must be an array, got: #{value.class}"
      end

      value.each do |arg|
        unless arg.is_a?(String)
          raise ArgumentError, "Each pip arg must be a string, got: #{arg.inspect}"
        end
      end
    end

    defaultto []
  end

  # Property to track whether requirements are in sync
  # This ensures the provider's flush method is called on every Puppet run
  newproperty(:requirements_state) do
    desc 'Internal property to track requirements synchronization state. DO NOT SET MANUALLY.'

    defaultto :insync

    def retrieve
      # Always return the current state from the provider
      provider.requirements_in_sync? ? :insync : :out_of_sync
    end

    def insync?(is)
      # Check if current state matches what we expect
      is == :insync
    end

    # This ensures sync_requirements is called when out of sync
    def sync
      # The actual sync happens in the provider's flush method
      :insync
    end
  end

  # Validation
  validate do
    if self[:requirements].empty? && self[:requirements_files].empty? && self[:ensure] == :present
      debug('No requirements specified - venv will be created but no packages installed')
    end
  end

  # Auto-require requirements files
  autorequire(:file) do
    self[:requirements_files]
  end
end
