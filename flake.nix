{
  description = "qylock — SDDM theme collection";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forEachSystem =
        f:
        builtins.listToAttrs (
          map (system: {
            name = system;
            value = f nixpkgs.legacyPackages.${system};
          }) systems
        );

      # ---------------------------------------------------------------------------
      # mkQylockPkgs
      #
      # Produces the derivations and helper functions used by both the NixOS module
      # and the Home Manager module.  Called once per pkgs instance so that
      # cross-compilation and multi-host flakes work correctly.
      # ---------------------------------------------------------------------------
      mkQylockPkgs = pkgs: rec {

        # ── Quickshell lockscreen shell directory ─────────────────────────────
        # A store path containing:
        #   lock_shell.qml   — QML entry point for the Quickshell lockscreen
        #   shim/            — SddmShim.qml (mocks SDDM globals for qs)
        #   imports/         — SddmComponents shim (TextConstants, LayoutMirroring)
        #   themes_link/     — symlink into the flake source themes/ directory
        qylockShell = pkgs.runCommand "qylock-shell" { } ''
          mkdir -p $out
          cp ${self}/quickshell-lockscreen/lock_shell.qml $out/lock_shell.qml
          cp -r --no-preserve=mode,ownership \
            ${self}/quickshell-lockscreen/shim $out/shim
          cp -r --no-preserve=mode,ownership \
            ${self}/quickshell-lockscreen/imports $out/imports
          cp -r --no-preserve=mode,ownership \
            ${self}/themes $out/themes_link
        '';

        # ── qylock-lock script ────────────────────────────────────────────────
        # Wraps `quickshell` with the correct QML_IMPORT_PATH so that:
        #   • SddmComponents shim is found (provides TextConstants etc. to themes)
        #   • Qt5Compat.GraphicalEffects is found (qt5compat)
        #   • QtMultimedia is found (qtmultimedia)
        # The theme name is baked in at build time; users can override at runtime
        # by passing a different QS_THEME value before calling the script.
        mkLockScript =
          theme:
          pkgs.writeShellScriptBin "qylock-lock" ''
            export QML_IMPORT_PATH="${qylockShell}/imports:${pkgs.kdePackages.qt5compat}/lib/qt-6/qml:${pkgs.qt6.qtmultimedia}/lib/qt-6/qml''${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}"
            export QML2_IMPORT_PATH="$QML_IMPORT_PATH"
            export QML_XHR_ALLOW_FILE_READ=1
            export QS_THEME="${theme}"
            exec ${pkgs.quickshell}/bin/quickshell -p ${qylockShell}/lock_shell.qml "$@"
          '';

        # ── SDDM theme package ────────────────────────────────────────────────
        # Installs a qylock theme under $out/share/sddm/themes/<leaf>.
        # Themes use Qt6-native imports directly (Qt5Compat.GraphicalEffects,
        # QtMultimedia) so no patching or shim injection is required.  The
        # qt5compat and qtmultimedia packages are added to the greeter environment
        # by nixos.nix.
        mkSddmThemePkg =
          themePath: extraFonts:
          let
            safeName = builtins.replaceStrings [ "/" ] [ "-" ] themePath;
            themeLeaf = builtins.baseNameOf themePath;
          in
          pkgs.runCommand "qylock-sddm-${safeName}" { } ''
            mkdir -p $out/share/sddm/themes
            cp -r --no-preserve=mode,ownership \
              ${self}/themes/${themePath} $out/share/sddm/themes/

            ${pkgs.lib.concatMapStrings (font: ''
              mkdir -p "$out/share/sddm/themes/${themeLeaf}/font"
              fontName=$(basename "${font}" | sed 's/^[a-z0-9]\{32\}-//')
              cp "${font}" "$out/share/sddm/themes/${themeLeaf}/font/$fontName"
            '') extraFonts}
          '';

        # ── Patched SDDM package ──────────────────────────────────────────────
        # NixOS's Qt6-only SDDM build ships the greeter as `sddm-greeter-qt6` but
        # some internal SDDM code paths still look for the bare `sddm-greeter` name.
        # Adding the symlink here avoids a "requires missing sddm-greeter" warning
        # in the display-manager journal.
        sddmPatched = pkgs.kdePackages.sddm.overrideAttrs (old: {
          buildCommand = old.buildCommand + ''
            ln -s $out/bin/sddm-greeter-qt6 $out/bin/sddm-greeter
          '';
        });

      };
    in
    {
      # ── packages ──────────────────────────────────────────────────────────────
      # packages.<s>.default  — qylock-lock script (Genshin theme baked in)
      # packages.<s>.shell    — raw Quickshell lockscreen store path
      packages = forEachSystem (
        pkgs:
        let
          q = mkQylockPkgs pkgs;
        in
        {
          default = q.mkLockScript "Genshin";
          shell = q.qylockShell;
        }
      );

      # ── NixOS module ──────────────────────────────────────────────────────────
      # Add to your flake inputs, then:
      #
      #   programs.qylock = {
      #     enable    = true;
      #     theme     = "terraria";   # Quickshell lockscreen theme
      #     sddmTheme = "cyberpunk";  # optional: install + activate an SDDM theme
      #   };
      nixosModules.default = import ./modules/nixos.nix { inherit self mkQylockPkgs; };

      # ── Home Manager module ───────────────────────────────────────────────────
      # Add to your flake inputs, then:
      #
      #   programs.qylock = {
      #     enable = true;
      #     theme  = "terraria";
      #   };
      homeManagerModules.default = import ./modules/home-manager.nix { inherit self mkQylockPkgs; };

      # ── dev shell ─────────────────────────────────────────────────────────────
      devShells = forEachSystem (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            kdePackages.sddm # sddm-greeter-qt6 test binary
            kdePackages.qt5compat # Qt5Compat.GraphicalEffects
            qt6.qtmultimedia # QtMultimedia (required by video themes)
            qt6.qtdeclarative # QtQuick / QML engine
            qt6.qttools # qmllint, qmlformat
            quickshell # Quickshell lockscreen runner
            fzf # used by sddm.sh / quickshell.sh installers
          ];

          shellHook = ''
            export QML_IMPORT_PATH="$PWD/quickshell-lockscreen/imports:${pkgs.kdePackages.qt5compat}/lib/qt-6/qml:${pkgs.qt6.qtmultimedia}/lib/qt-6/qml''${QML_IMPORT_PATH:+:$QML_IMPORT_PATH}"
            export QML_XHR_ALLOW_FILE_READ=1

            # ── testTheme <theme-path> [font-file ...] ──────────────────────
            # Copies a theme into a disposable temp directory, optionally
            # injects font files, then launches sddm-greeter-qt6 in test mode.
            #
            # Usage:
            #   testTheme Genshin
            #   testTheme Genshin ~/fonts/zhcn.ttf
            #   testTheme cozytile/Cozy
            #   testTheme tui/Amber
            testTheme() {
              local theme="''${1:?Usage: testTheme <theme-path> [font-file ...]}"
              shift
              local leaf
              leaf=$(basename "$theme")
              local tmp
              tmp=$(mktemp -d --suffix=-qylock-test)

              echo "  Copying themes/$theme → $tmp/$leaf"
              cp -r "$PWD/themes/$theme" "$tmp/"

              if [[ $# -gt 0 ]]; then
                echo "  Copying fonts..."
                mkdir -p "$tmp/$leaf/font"
                for font in "$@"; do
                  cp "$font" "$tmp/$leaf/font/$(basename "$font")"
                done
              fi

              echo "  Launching sddm-greeter-qt6 --test-mode..."
              sddm-greeter-qt6 --test-mode --theme "$tmp/$leaf"

              rm -rf "$tmp"
            }

            # ── testLockscreen [theme-path] ──────────────────────────────────
            # Points themes_link at the local themes/ directory and launches
            # the Quickshell lockscreen.  Restores the previous symlink on exit.
            #
            # Usage:
            #   testLockscreen
            #   testLockscreen Genshin
            #   testLockscreen tui/Crimson
            testLockscreen() {
              local theme="''${1:-Genshin}"

              local link="$PWD/quickshell-lockscreen/themes_link"
              local prev_link
              [[ -L "$link" ]] && prev_link=$(readlink "$link")
              ln -sfn "$PWD/themes" "$link"

              echo "  Launching Quickshell lockscreen (QS_THEME=$theme)..."
              QS_THEME="$theme" quickshell -p "$PWD/quickshell-lockscreen/lock_shell.qml"

              if [[ -n "''${prev_link:-}" ]]; then
                ln -sfn "$prev_link" "$link"
              else
                rm -f "$link"
              fi
            }

            echo "qylock dev shell"
            echo ""
            echo "  Test an SDDM theme:"
            echo "    testTheme Genshin"
            echo "    testTheme Genshin ~/fonts/zhcn.ttf"
            echo "    testTheme cozytile/Cozy"
            echo ""
            echo "  Test the Quickshell lockscreen:"
            echo "    testLockscreen Genshin"
            echo "    testLockscreen tui/Crimson"
            echo ""
            echo "  Test a theme directly (source tree):"
            echo "    sddm-greeter-qt6 --test-mode --theme \$PWD/themes/<name>"
            echo ""
          '';
        };
      });
    };
}
