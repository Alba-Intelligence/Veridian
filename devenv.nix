{ ... }:
{
  # spec-check.nix: Allium CLI, Quint and the specification checks.
  # code-check.nix: Elixir, Julia and PostgreSQL, and the code checks.
  imports = [
    ./spec-check.nix
    ./code-check.nix
  ];
}
