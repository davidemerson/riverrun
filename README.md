# riverrun
an infinite community playlist

1. Install minimal Debian Linux
2. Clone this repo
	* `git clone https://github.com/davidemerson/riverrun.git`
3. Edit the `riverrun_config.toml` file as appropriate for you
	* `nano riverrun/riverrun_config.toml`
4. Run, as root, the `store_secrets.sh` script to commit secrets (Icecast credentials) to a safe place
	* `./riverrun/store_secrets.sh`
5. Run, as root, the setup script
	* `./riverrun/riverrun_setup.sh`