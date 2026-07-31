# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# It is also run automatically by `mix ecto.setup` and `mix ecto.reset`.
#
# This file is intentionally empty. It previously created a demo administrator
# with a password committed to the repository, which would have become a
# known-credential account on any environment the seeds were run against.
#
# Create your first account by registering at /users/register and confirming it
# from the local mailbox at /dev/mailbox.
#
# Anything added here must be safe to run in every environment, or guarded:
#
#     if Mix.env() != :prod do
#       ...
#     end
#
# Do not hardcode credentials. Read them from the environment instead:
#
#     System.fetch_env!("SEED_ADMIN_PASSWORD")
