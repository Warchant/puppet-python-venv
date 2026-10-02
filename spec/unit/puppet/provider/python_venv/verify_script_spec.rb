# frozen_string_literal: true

require 'spec_helper'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'base64'
require 'digest'

# Runs the provider's inline VERIFY_SCRIPT with a real python3 against small venvs
# built per example (python3 -m venv --without-pip: fast, no network).
describe 'python_venv pip provider VERIFY_SCRIPT' do
  let(:script) { Puppet::Type.type(:python_venv).provider(:pip)::VERIFY_SCRIPT }
  let(:python3) { Puppet::Util.which('python3') }
  let(:tmpdir) { Dir.mktmpdir('verify_script_spec') }
  let(:venv) { File.join(tmpdir, 'venv') }
  let(:venv_python) { File.join(venv, 'bin', 'python') }
  let(:site_packages) { Dir.glob(File.join(venv, 'lib', 'python*', 'site-packages')).first }

  before(:each) do
    unless python3
      raise 'python3 is required to test VERIFY_SCRIPT' if ENV['CI']
      skip 'python3 is not available'
    end
    _out, err, status = Open3.capture3(python3, '-m', 'venv', '--without-pip', venv)
    raise "python3 -m venv failed: #{err}" unless status.success?
  end

  after(:each) { FileUtils.rm_rf(tmpdir) }

  def record_hash(content)
    "sha256=#{Base64.urlsafe_encode64(Digest::SHA256.digest(content), padding: false)}"
  end

  # Install a fake distribution: files are {path relative to site-packages => content}.
  # Returns the dist-info directory.
  def add_dist(name, version, files, metadata: nil, record: nil)
    dist_info = File.join(site_packages, "#{name.tr('-', '_')}-#{version}.dist-info")
    FileUtils.mkdir_p(dist_info)
    File.write(File.join(dist_info, 'METADATA'), metadata || "Metadata-Version: 2.1\nName: #{name}\nVersion: #{version}\n")

    rows = files.map do |rel, content|
      path = File.expand_path(rel, site_packages)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, content)
      "#{rel},#{record_hash(content)},#{content.bytesize}"
    end
    rows << "#{File.basename(dist_info)}/RECORD,,"
    File.write(File.join(dist_info, 'RECORD'), record || "#{rows.join("\n")}\n")
    dist_info
  end

  def verify(mode, python: venv_python, path: venv)
    out, err, status = Open3.capture3(python, '-I', '-c', script, mode, path)
    result = JSON.parse(out)
    result['exitstatus'] = status.exitstatus
    result['stderr'] = err
    result
  end

  def expect_ok(result)
    expect(result['errors']).to eq([])
    expect(result['ok']).to be true
    expect(result['exitstatus']).to eq(0)
  end

  def expect_failure(result, pattern)
    expect(result['ok']).to be false
    expect(result['exitstatus']).to eq(1)
    expect(result['errors'].join("\n")).to match(pattern)
  end

  context 'with a valid venv' do
    before(:each) do
      add_dist('My_Pkg.Name', '1.2.3', { 'my_pkg/__init__.py' => "VALUE = 1\n", 'my_pkg/empty.py' => '' })
    end

    ['size', 'hash'].each do |mode|
      it "passes in #{mode} mode and reports the venv" do
        result = verify(mode)
        expect_ok(result)
        expect(result['mode']).to eq(mode)
        expect(result['files']).to eq(3)
        expect(result['python']).to match(%r{\A3\.\d+\z})
        expect(result['executable']).to eq(File.realpath(venv_python))
      end
    end

    it 'normalizes distribution names (PEP 503)' do
      expect(verify('size')['distributions']).to eq(['my-pkg-name==1.2.3'])
    end

    it 'lists distributions sorted' do
      add_dist('aaa', '0.1', { 'aaa.py' => 'a' })
      expect(verify('size')['distributions']).to eq(['aaa==0.1', 'my-pkg-name==1.2.3'])
    end

    it 'emits a single JSON object on stdout and nothing on stderr' do
      expect(verify('hash')['stderr']).to eq('')
    end
  end

  it 'passes for a venv without any distributions' do
    result = verify('hash')
    expect_ok(result)
    expect(result['distributions']).to eq([])
    expect(result['files']).to eq(0)
  end

  describe 'file checks' do
    let(:target) { File.join(site_packages, 'pkg', 'mod.py') }

    before(:each) { add_dist('pkg', '1.0', { 'pkg/mod.py' => "print('hello world')\n" }) }

    it 'detects a zero-sized file in size mode' do
      File.write(target, '')
      expect_failure(verify('size'), %r{pkg/mod\.py: size 0, expected 21})
    end

    it 'detects a truncated file in size mode' do
      File.write(target, 'print(')
      expect_failure(verify('size'), %r{size 6, expected 21})
    end

    it 'misses same-size corruption in size mode but catches it in hash mode' do
      File.write(target, "print('hellO world')\n")
      expect_ok(verify('size'))
      expect_failure(verify('hash'), %r{pkg/mod\.py: sha256 mismatch})
    end

    it 'detects a missing file' do
      File.delete(target)
      expect_failure(verify('size'), %r{pkg/mod\.py: missing})
    end

    it 'detects a directory in place of a file' do
      File.delete(target)
      Dir.mkdir(target)
      expect_failure(verify('size'), %r{not a regular file})
    end

    it 'follows symlinks to the real file' do
      real = File.join(tmpdir, 'real.py')
      File.write(real, File.read(target))
      File.delete(target)
      File.symlink(real, target)
      expect_ok(verify('hash'))
    end
  end

  describe 'paths outside site-packages' do
    it 'resolves ../../../bin entries relative to site-packages' do
      add_dist('tool', '1.0', { '../../../bin/tool' => "#!/bin/sh\necho tool\n" })
      expect(File.exist?(File.join(venv, 'bin', 'tool'))).to be true
      expect_ok(verify('hash'))
    end

    it 'detects a missing console script' do
      add_dist('tool', '1.0', { '../../../bin/tool' => "#!/bin/sh\necho tool\n" })
      File.delete(File.join(venv, 'bin', 'tool'))
      expect_failure(verify('size'), %r{bin/tool: missing})
    end

    it 'checks absolute paths as they are' do
      outside = File.join(tmpdir, 'data.txt')
      add_dist('abs', '1.0', {}, record: "#{outside},#{record_hash('data')},4\n")
      File.write(outside, 'data')
      expect_ok(verify('hash'))
      File.write(outside, 'DATA')
      expect_failure(verify('hash'), %r{data\.txt: sha256 mismatch})
    end
  end

  describe 'RECORD rows' do
    it 'checks only existence for rows without hash and size (RECORD itself, .pyc)' do
      add_dist('pkg', '1.0', {}, record: "pkg/x.pyc,,\npkg-1.0.dist-info/RECORD,,\n")
      FileUtils.mkdir_p(File.join(site_packages, 'pkg'))
      File.write(File.join(site_packages, 'pkg', 'x.pyc'), 'anything')
      expect_ok(verify('hash'))
    end

    it 'checks the size when only the hash is missing' do
      add_dist('pkg', '1.0', {}, record: "pkg/x.py,,5\n")
      FileUtils.mkdir_p(File.join(site_packages, 'pkg'))
      File.write(File.join(site_packages, 'pkg', 'x.py'), 'abc')
      expect_failure(verify('hash'), %r{size 3, expected 5})
    end

    it 'ignores blank lines' do
      add_dist('pkg', '1.0', {}, record: "\npkg-1.0.dist-info/RECORD,,\n\n")
      expect_ok(verify('size'))
    end

    it 'handles quoted paths containing commas' do
      add_dist('pkg', '1.0', {}, record: "\"pkg/a,b.txt\",#{record_hash('x')},1\n")
      FileUtils.mkdir_p(File.join(site_packages, 'pkg'))
      File.write(File.join(site_packages, 'pkg', 'a,b.txt'), 'x')
      expect_ok(verify('hash'))
    end

    it 'rejects a malformed row' do
      add_dist('pkg', '1.0', {}, record: "pkg/x.py,sha256=abc\n")
      expect_failure(verify('size'), %r{malformed RECORD row})
    end

    it 'rejects an unknown hash algorithm' do
      add_dist('pkg', '1.0', { 'pkg/x.py' => 'x' })
      record = Dir.glob(File.join(site_packages, '*.dist-info', 'RECORD')).first
      File.write(record, File.read(record).sub('sha256=', 'nosuchalgo='))
      expect_failure(verify('hash'), %r{pkg/x\.py: cannot hash})
    end

    it 'fails closed on a non-numeric size' do
      add_dist('pkg', '1.0', {}, record: "pkg-1.0.dist-info/RECORD,,abc\n")
      result = verify('size')
      expect(result['ok']).to be false
      expect(result['errors'].first).to match(%r{verifier crashed})
    end
  end

  describe 'distribution metadata' do
    it 'rejects a dist-info without RECORD' do
      dist_info = add_dist('pkg', '1.0', { 'pkg/x.py' => 'x' })
      File.delete(File.join(dist_info, 'RECORD'))
      expect_failure(verify('size'), %r{pkg-1\.0\.dist-info: cannot read metadata})
    end

    it 'rejects an empty RECORD' do
      add_dist('pkg', '1.0', {}, record: '')
      expect_failure(verify('size'), %r{RECORD is empty})
    end

    it 'rejects a dist-info without METADATA' do
      dist_info = add_dist('pkg', '1.0', { 'pkg/x.py' => 'x' })
      File.delete(File.join(dist_info, 'METADATA'))
      expect_failure(verify('size'), %r{cannot read metadata})
    end

    it 'rejects METADATA without a Version' do
      add_dist('pkg', '1.0', { 'pkg/x.py' => 'x' }, metadata: "Metadata-Version: 2.1\nName: pkg\n")
      expect_failure(verify('size'), %r{METADATA has no Name/Version})
    end

    it 'rejects a zero-sized METADATA' do
      add_dist('pkg', '1.0', { 'pkg/x.py' => 'x' }, metadata: '')
      expect_failure(verify('size'), %r{METADATA has no Name/Version})
    end

    it 'rejects legacy egg-info installs, which cannot be verified' do
      FileUtils.mkdir_p(File.join(site_packages, 'old-1.0-py3.egg-info'))
      expect_failure(verify('size'), %r{legacy egg-info})
    end

    it 'ignores other entries in site-packages' do
      File.write(File.join(site_packages, 'distutils-precedence.pth'), 'import os')
      FileUtils.mkdir_p(File.join(site_packages, '__pycache__'))
      expect_ok(verify('size'))
    end
  end

  describe 'interpreter checks' do
    it 'rejects a venv path that is not the interpreter prefix' do
      other = File.join(tmpdir, 'other')
      Dir.mkdir(other)
      expect_failure(verify('size', path: other), %r{is not the venv})
    end

    it 'rejects an interpreter that is not running inside a venv' do
      expect_failure(verify('size', python: python3), %r{not running inside a venv})
    end

    it 'fails when site-packages is missing (e.g. after a python minor upgrade)' do
      FileUtils.rm_r(site_packages)
      expect_failure(verify('size'), %r{no site-packages directory for python3\.\d+})
    end
  end

  it 'caps the reported errors but counts all of them' do
    files = (1..60).map { |i| ["pkg/f#{i}.py", 'x'] }.to_h
    add_dist('pkg', '1.0', files)
    files.each_key { |rel| File.delete(File.join(site_packages, rel)) }
    result = verify('size')
    expect(result['ok']).to be false
    expect(result['error_count']).to eq(60)
    expect(result['errors'].size).to eq(50)
  end
end
