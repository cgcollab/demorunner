# demorunner
sh script to automate shell controlled demos.

This script executes a sequence of shell commands saved in a separate file 
(this file name is provided as an input parameter for the script).  

The goal of the script is to offer a pre-packaged demo experience controlled by the operator with 
control over speed and text colors for better clarity for the final user.

The initial version allows for execution of extra commands during the demo and the possibility to start 
the demo from a specific line number (where feasible).

Run the script without arguments to show the help. (Also copied below)

# installation

### prerequisites

Install pv:
```
brew install pv
```

### recommendations

Copy `demorunner.sh` to a directory that is included in your PATH by default.

# run sample commands

Optionally add a line number at the end to start at a different line
```
source ./demorunner.sh sample_commands.txt
```

Optionally add a line number at the end to start at a different line
```
source ./demorunner.sh sample_commands.txt 2
```

# demorunner.sh usage instructions:

```
$ demorunner.sh

This utility enables the simulation of 'live typing' for command-line driven demos by echoing and executing
a list of commands that you provide in a 'commands file'.

Usage:
source ./demorunner.sh (commands-file) [start-with-line-number]

Command-line arguments:
  commands-file           - Name of the file with the list of commands to execute. Required.
  start-with-line-number  - Line number in the commands file at which to begin execution. Optional. Default is 1.
                            #_ECHO_ON & #_ECHO_OFF commands above the starting line will still be respected, but
                            other lines will be ignored.

The following flags can be used in the commands file:
  #_ECHO_ON   - Turns on echoing and execution of subsequent commands. Must be placed in its own line.
                When #_ECHO_ON is enabled, user must press the Return key once to echo the next command, and again
                to execute it. This is the default mode.
  #_ECHO_OFF  - Turns off echoing of subsequent commands. Commands will be executed immediately, without user input.
                Must be placed in its own line.
  #_ECHO_#    - Strips tag and echoes command starting from #. Must be placed at the beginning of the line.

Otherwise, lines starting with # will be ignored.

The following environment variables can be used to modify the behavior of the script:
  DEMO_COLOR  - May be yellow, blue, white, or black. Default is yellow.
  DEMO_DELAY  - Controls the rate of the echoing of commands to simulate live typing. Default is 10.
                Set to 0 to disable rate-limiting. Increase the setting to make typing appear faster.

During execution of your commands file, you may also type a custom command at any time. Once your custom command is
executed, press Return at the next empty prompt to continue with the next command from the commands file.

--- Known issues/To-do List:

- Up/Down/Left/Right arrows have no effect.
- Tab/autocompletion does not work.
```

# limitations

- Up/Down/Left/Right arrows have no effect
- Tab/autocompletion does not work

We are not sure when we'll have a chance to implement arrows and tabbing, but if you want to give it a shot, we'd love your contributions via a pull request!
