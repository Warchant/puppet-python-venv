file { [
	'/opt/apps/myapp',
	'/opt/apps/myapp/requirements',
]:
	ensure => directory,
}

file { '/opt/apps/myapp/requirements/base.txt':
	ensure  => file,
	content => "requests==2.32.3\n",
}

file { '/opt/apps/myapp/requirements/prod.txt':
	ensure  => file,
	content => "fastapi==0.115.0\n",
}

python_venv { '/opt/apps/myapp/.venv':
	ensure               => present,
	python_executable    => '/usr/bin/python3',
	system_site_packages => false,
	requirements_files   => [
		'/opt/apps/myapp/requirements/base.txt',
		'/opt/apps/myapp/requirements/prod.txt',
	],
	requirements         => [
		'uvicorn[standard]==0.30.6',
		'gunicorn==22.0.0',
	],
	pip_args             => ['--no-cache-dir'],
}
