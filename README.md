# demorunner

A Bash utility for automating **live shell demos** — simulating typed commands with adjustable speed, color, and interactive control.

`demorunner.sh` executes a sequence of shell commands stored in a separate *commands file* (provided as an argument).  
It allows the demo operator to step through commands one by one, type additional ad-hoc commands, or resume automated playback at any point in the script.

---

## ✨ Features

- Simulates **live typing** with adjustable speed and color
- Allows **manual control** of demo flow — press Return once to show a command, again to run it
- Supports **ad-hoc commands** between scripted lines
- Keeps **command history** and supports **in-line editing** using arrow keys
- Respects `#_ECHO_ON` / `#_ECHO_OFF` flags for interactive or silent execution
- Can start execution from any line number in the file
- Supports scripted **multiline commands** (backslash continuation (\), unclosed quotes, heredocs (<< EOF), and block constructs (if/fi, for/while/done, case/esac, function/{}))

---

## ⚙️ Installation

### Prerequisites

Install [`pv`](https://www.ivarch.com/programs/pv.shtml), used to control simulated typing speed:

```bash
brew install pv
```

### Recommendation

Copy `demorunner.sh` to a directory included in your `PATH` for convenient use.

---

## ▶️ Usage

### Basic Example

See [sample_commands.txt](sample_commands.txt) and [sample_multiline_commands.txt](sample_multiline_commands.txt) for examples.

```bash
./demorunner.sh sample_commands.txt
```

### Start from a Specific Line

```bash
./demorunner.sh sample_commands.txt 2
```

Run the script with no arguments to display the built-in help:

```bash
./demorunner.sh
```

---

## 📘 Usage Instructions

```
This utility enables the simulation of 'live typing' for command-line driven demos by echoing and executing
a list of commands that you provide in a 'commands file'.

Usage:
  ./demorunner.sh <commands-file> [start-with-line-number]
  (Run directly, not with 'source', to prevent mixing its environment with your current shell.)

Command-line arguments:
  commands-file           - Name of the file with the list of commands to execute. Required.
  start-with-line-number  - Line number in the commands file at which to begin execution. Optional. Default is 1.
                            The most recent #_ECHO_ON or #_ECHO_OFF flag above this line will still be respected.

Commands file features:
  The following flags can be used in the commands file:
    #_ECHO_ON   - Enables interactive echoing; subsequent commands are shown and executed one by one.
    #_ECHO_OFF  - Disables interactive echoing; subsequent commands are executed silently (no prompts or typing).
                  Note: command output still appears normally unless redirected (e.g., '> /dev/null').
    #_ECHO_#    - Strips tag and echoes the rest of the line as a comment (prefixed with #).
    #_ECHO_E_#  - Same as #_ECHO_#, but evaluates variables before echoing the comment.

  Multiline commands are supported:
    - Backslash continuation (\)
    - Unclosed quotes (single or double)
    - Heredocs (<< EOF, << 'EOF', << "EOF")
    - Block constructs (if/fi, for/while/done, case/esac, function/{})

  Otherwise, lines starting with # or containing only whitespace will be ignored (as in a normal shell script).

Interactive features:
  - When #_ECHO_ON is enabled, press Return once to display the next command, and again to execute it.
  - Ad-hoc typing: at the prompt, enter any command; press Return on an empty line to resume scripted commands.
  - Up/Down arrows: browse command history (does not include commands executed silently while #_ECHO_OFF is active).
  - Left/Right arrows: move the cursor for in-line editing.

Environment variables:
  DEMO_COLOR  - Sets the color of the prompt and the displayed command.
                May be yellow, blue, white, or black. Default is yellow.
  DEMO_DELAY  - Controls the simulated typing speed. Default is 15.
                Set to 0 to disable rate-limiting; increase to make typing appear faster.
```

---

## ⚠️ Known Limitations

  - For ad-hoc commands, escape sequences and control characters other than arrow keys, Backspace, and Return are ignored (e.g., Tab, Ctrl+L).
  - Tab autocompletion is not supported.
  - Ad-hoc multi-line commands are not supported (only scripted multi-line commands).
  - For scripted multi-line commands, editing is not supported (left arrow and Backspace are disabled).

---

## 🪪 License

MIT License © 2025  
Created by Maria Gabriella Brodi and Cora Iberkleid.
