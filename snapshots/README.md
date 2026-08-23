# snapshots/

Small backup copies that live inside the repo for git-versioning — currently dotfiles
and tool histories (which backup.sh also tars to the destination). Secrets never go
here (they go to the drive, 0600). Auto-populated on `tool_histories` backup if you
enable the mirror toggle in the manifest.