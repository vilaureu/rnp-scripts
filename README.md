# Scripts for Computer Networks in Practice

This is a collection of scripted solutions for the practical exercises of the
_Computer Networks in Practice_ course lectured by _Dr. Marius Feldmann_ at the
_TU Dresden_ in 2022/23.

## Project Structure

The solution for each task is contained in a separate folder.
A solution mainly consist of an executable shell scripts (`demonstrate.sh`) and
some configuration files.
The setup, test and benchmark steps of an exercise solution can be demonstrated
by executing such a shell script.
At the start, a script performs setup procedures and starts demons.
Afterwards, the effects of the performed steps are demonstrated.
Most of the time, [_tmux_](https://github.com/tmux/tmux/wiki) is used to display
the output of multiple applications simultaneously.
If the demonstration has multiple steps, you might need to press _Enter_ to
continue with the next step.

## Usage

```
$ cd ./<SOLUTION FOLDER>/
$ sudo ./demonstrate.sh
```

The demonstration scripts often need root privileges to run.
A _Linux_ system with the required software installed is needed.

## License

See the `LICENSE` file.
