import Config

# For development, we disable any cache and enable
# debugging and code reloading.
#
# The watchers configuration can be used to run external
# watchers to your application.

# Import local configuration if it exists, which is ignored by git
if File.exists?("config/dev.local.exs") do
  import_config "dev.local.exs"
end
