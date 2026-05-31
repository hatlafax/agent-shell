;;; agent-shell-jetbrains.el --- JetBrains Junie agent configurations -*- lexical-binding: t; -*-

;; Copyright (C) 2024 Alvaro Ramirez

;; Author: Alvaro Ramirez https://xenodium.com
;; URL: https://github.com/xenodium/agent-shell

;; This package is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This package is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; This file includes JetBrains Junie-specific configurations.
;;

;;; Code:

(eval-when-compile
  (require 'cl-lib))
(require 'shell-maker)
(require 'acp)

(declare-function agent-shell--indent-string "agent-shell")
(declare-function agent-shell--interpolate-gradient "agent-shell")
(declare-function agent-shell--make-acp-client "agent-shell")
(declare-function agent-shell-make-agent-config "agent-shell")
(autoload 'agent-shell-make-agent-config "agent-shell")
(declare-function agent-shell--dwim "agent-shell")

(cl-defun agent-shell-jetbrains-make-authentication (&key api-key login oauth none)
  "Create JetBrains authentication configuration.

API-KEY is the JetBrains Junie API key string or function that returns it.
LOGIN when non-nil indicates to use login-based authentication.
OAUTH is an OAuth token string or a function returning one.
NONE when non-nil indicates no authentication method is used.

Only one of API-KEY, LOGIN, OAUTH, or NONE should be provided."
  (when (> (seq-count #'identity (list api-key login oauth)) 1)
    (error "Cannot specify multiple authentication methods - choose one"))
  (unless (> (seq-count #'identity (list api-key login oauth none)) 0)
    (error "Must specify one of :api-key, :login, or :oauth"))
  (cond
   (api-key `((:api-key . ,api-key)))
   (login `((:login . t)))
   (oauth `((:oauth .  ,oauth)))
   (none `((:none . t)))))

(defcustom agent-shell-jetbrains-authentication
  (agent-shell-jetbrains-make-authentication :login t)
  "Configuration for JetBrains authentication.

For login-based authentication (default):

  (setq agent-shell-jetbrains-authentication
        (agent-shell-jetbrains-make-authentication :login t))

For API key (string):

  (setq agent-shell-jetbrains-authentication
        (agent-shell-jetbrains-make-authentication :api-key \"your-key\"))

For API key (function):

  (setq agent-shell-jetbrains-authentication
        (agent-shell-jetbrains-make-authentication :api-key (lambda () ...)))

For OAuth token:

  (setq agent-shell-jetbrains-authentication
        (agent-shell-jetbrains-make-authentication :oauth \"your-token\"))

  or

  (setq agent-shell-jetbrains-authentication
        (agent-shell-jetbrains-make-authentication :oauth (lambda () ... )))

For no authentication (when using alternative authentication methods):

  (setq agent-shell-jetbrains-authentication
        (agent-shell-jetbrains-make-authentication :none t))"
  :type 'alist
  :group 'agent-shell)

(defcustom agent-shell-jetbrains-junie-acp-command
  '("junie" "--acp" "true")
  "Command and parameters for the Junie client.

The first element is the command name, and the rest are command parameters."
  :type '(repeat string)
  :group 'agent-shell)

(defcustom agent-shell-jetbrains-junie-environment
  nil
  "Environment variables for the Junie client.

This should be a list of environment variables to be used when
starting the Junie client process.

Example usage to set custom environment variables:

  (setq agent-shell-jetbrains-junie-environment
        (`agent-shell-make-environment-variables'
         \"MY_VAR\" \"some-value\"
         \"MY_OTHER_VAR\" \"another-value\"))"
  :type '(repeat string)
  :group 'agent-shell)

(defun agent-shell-jetbrains-make-junie-config ()
  "Create a Junie CLI agent configuration.

Returns an agent configuration alist using `agent-shell-make-agent-config'."
  (when (and (boundp 'agent-shell-jetbrains-key) agent-shell-jetbrains-key)
    (user-error "Please migrate to use agent-shell-jetbrains-authentication and eval (setq agent-shell-jetbrains-key nil)"))
  (agent-shell-make-agent-config
   :identifier 'junie-cli
   :mode-line-name "Junie"
   :buffer-name "Junie"
   :shell-prompt "Junie> "
   :shell-prompt-regexp "Junie> "
   :icon-name "junie.png"
   :welcome-function #'agent-shell-jetbrains--junie-welcome-message
   :needs-authentication (not (map-elt agent-shell-jetbrains-authentication :none))
   :authenticate-request-maker (lambda ()
                                 (cond ((map-elt agent-shell-jetbrains-authentication :api-key)
                                        ;; TODO: Save authentication methods from
                                        ;; initialization and resolve :method-id
                                        ;; to :method which came from the agent.
                                        (acp-make-authenticate-request
                                         :method-id "jetbrains-api-key"
                                         :method '((id . "jetbrains-api-key")
                                                   (name . "Use Junie API key")
                                                   (description . "Requires setting the `JUNIE_API_KEY` environment variable"))))
                                       ((map-elt agent-shell-jetbrains-authentication :oauth)
                                            (list (format "JUNIE_OAUTH_TOKEN=%s"
                                                (agent-shell-jetbrains-oauth-token))))
                                       ((map-elt agent-shell-jetbrains-authentication :none)
                                        nil)
                                       (t
                                        ;; TODO: Save authentication methods from
                                        ;; initialization and resolve :method-id
                                        ;; to :method which came from the agent.
                                        (acp-make-authenticate-request
                                         :method-id "oauth-personal"
                                         :method '((id . "oauth-personal")
                                                   (name . "Log in with JetBrains")
                                                   (description . ""))))))
   :client-maker (lambda (buffer)
                   (agent-shell-jetbrains-make-junie-client :buffer buffer))
   :install-instructions "See https://junie.jetbrains.com/ for installation."))

(defun agent-shell-jetbrains-start-junie ()
  "Start an interactive Junie CLI agent shell."
  (interactive)
  (agent-shell--dwim :config (agent-shell-jetbrains-make-junie-config)
                     :new-shell t))

(cl-defun agent-shell-jetbrains-make-junie-client (&key buffer)
  "Create a Junie client using configured authentication with BUFFER as context.

Uses `agent-shell-jetbrains-authentication' for authentication configuration."
  (unless buffer
    (error "Missing required argument: :buffer"))
  (when (and (boundp 'agent-shell-jetbrains-key) agent-shell-jetbrains-key)
    (user-error "Please migrate to use agent-shell-jetbrains-authentication and eval (setq agent-shell-jetbrains-key nil)"))
  (when (and (boundp 'agent-shell-jetbrains-command) agent-shell-jetbrains-junie-command)
    (user-error "Please migrate to use agent-shell-jetbrains-junie-acp-command and eval (setq agent-shell-jetbrains-junie-command nil)"))
  (cond
   ((map-elt agent-shell-jetbrains-authentication :api-key)
    (agent-shell--make-acp-client :command (car agent-shell-jetbrains-junie-acp-command)
                                  :command-params (cdr agent-shell-jetbrains-junie-acp-command)
                                  :environment-variables (append (when-let ((api-key (agent-shell-jetbrains-key)))
                                                                   (list (format "JUNIE_API_KEY=%s" api-key)))
                                                                 agent-shell-jetbrains-junie-environment)
                                  :context-buffer buffer))
   ((map-elt agent-shell-jetbrains-authentication :login)
    (agent-shell--make-acp-client :command (car agent-shell-jetbrains-junie-acp-command)
                                  :command-params (cdr agent-shell-jetbrains-junie-acp-command)
                                  :environment-variables agent-shell-jetbrains-junie-environment
                                  :context-buffer buffer))
   ((map-elt agent-shell-jetbrains-authentication :vertex-ai)
    (agent-shell--make-acp-client :command (car agent-shell-jetbrains-junie-acp-command)
                                  :command-params (cdr agent-shell-jetbrains-junie-acp-command)
                                  :environment-variables agent-shell-jetbrains-junie-environment
                                  :context-buffer buffer))
   ((map-elt agent-shell-jetbrains-authentication :none)
    (agent-shell--make-acp-client :command (car agent-shell-jetbrains-junie-acp-command)
                                  :command-params (cdr agent-shell-jetbrains-junie-acp-command)
                                  :environment-variables agent-shell-jetbrains-junie-environment
                                  :context-buffer buffer))
   (t
    (error "Invalid authentication configuration"))))

(defun agent-shell-jetbrains--junie-welcome-message (config)
  "Return Junie CLI ASCII art as per own repo using `shell-maker' CONFIG."
  (let ((art (agent-shell--indent-string 4 (agent-shell-jetbrains--junie-ascii-art)))
        (message (string-trim-left (shell-maker-welcome-message config) "\n")))
    (concat "\n\n\n"
            art
            "\n\n"
            message)))

(defun agent-shell-jetbrains--junie-ascii-art ()
  "Generate Junie CLI ASCII art, inspired by its codebase."
  (let* ((text (string-trim "
███             ██████ █████    ████ ██████   █████ █████ ██████████
░░░███           ░░███ ░░███   ░███  ░░██████ ░░███ ░░███ ░░███░░░░░█
  ░░░███          ░███  ░███   ░███   ░███░███ ░███  ░███  ░███  █
    ░░░███    ░█  ░███  ░███   ░███   ░███░░███░███  ░███  ░██████
     ███░   ░██   ░███  ░███   ░███   ░███ ░░██████  ░███  ░███░░█
   ███░     ░███  ░███  ░███   ░███   ░███  ░░█████  ░███  ░███ ░   █
 ███░        ░████████  ████████████  █████  ░░█████ █████ ██████████
░░░           ░░░░░░░  ░░░░░░░░░░░░  ░░░░░    ░░░░░ ░░░░░ ░░░░░░░░░░" "\n"))
         (is-dark (eq (frame-parameter nil 'background-mode) 'dark))
         (gradient-colors (if is-dark
                              '("#4796E4" "#847ACE" "#C3677F")
                            '("#3B82F6" "#8B5CF6" "#DD4C4C")))
         (lines (split-string text "\n"))
         (result ""))
    (dolist (line lines)
      (let ((line-length (length line))
            (propertized-line ""))
        (dotimes (i line-length)
          (let* ((char (substring line i (1+ i)))
                 (progress (/ (float i) line-length))
                 (color (agent-shell--interpolate-gradient gradient-colors progress)))
            (setq propertized-line
                  (concat propertized-line
                          (propertize char 'font-lock-face `(:foreground ,color :inherit fixed-pitch))))))
        (setq result (concat result propertized-line "\n"))))
    (string-trim-right result)))

(defun agent-shell-jetbrains--junie-text ()
  "Colorized Junie text with colors."
  (let* ((is-dark (eq (frame-parameter nil 'background-mode) 'dark))
         (colors (if is-dark
                     '("#4796E4" "#6B82D9" "#847ACE" "#9E6FA8" "#B16C93" "#C3677F")
                   '("#3B82F6" "#5F6CF6" "#8B5CF6" "#A757D0" "#C354A0" "#DD4C4C")))
         (text "Junie")
         (result ""))
    (dotimes (i (length text))
      (setq result (concat result
                           (propertize (substring text i (1+ i))
                                       'font-lock-face `(:foreground ,(nth (mod i (length colors)) colors) :inherit fixed-pitch)))))
    result))

(defun agent-shell-jetbrains-key ()
  "Get the Junie API key."
  (cond ((stringp (map-elt agent-shell-jetbrains-authentication :api-key))
         (map-elt agent-shell-jetbrains-authentication :api-key))
        ((functionp (map-elt agent-shell-jetbrains-authentication :api-key))
         (condition-case _err
             (funcall (map-elt agent-shell-jetbrains-authentication :api-key))
           (error
            "Api key not found.  Check out `agent-shell-jetbrains-authentication'")))
        (t
         nil)))

(provide 'agent-shell-jetbrains)

;;; agent-shell-jetbrains.el ends here
