# How to Read the Code in This Repository (No Coding Experience Required)

This guide explains the handful of patterns that repeat throughout every
file in this project. All of these files are written in a language called
**Bash** (also called "shell script") — it's the language used to type
commands into a Linux terminal, just written down in advance as a file
instead of typed one line at a time. Once you recognize these dozen or so
patterns, you can follow almost any line in any file here.

---

## 1. Variables — naming a piece of information

```bash
name="Bob"
```

This says: *"remember the word Bob, and from now on, when I write `name`,
I mean Bob."* No spaces are allowed around the `=` sign — `name = "Bob"`
(with spaces) is actually wrong in Bash and will cause an error.

To **use** a variable later, put a `$` in front of it:

```bash
echo "Hello, $name"
```

`echo` just means "print this text to the screen." This line prints
`Hello, Bob`.

You'll also see `${name}` (with curly braces) — this means exactly the
same thing as `$name`. The braces are used when it's needed to clearly
mark where the variable name ends, especially right before more letters,
like `${name}s` (which means "the value of `name`, followed by the letter
s") — without the braces, `$names` would be read as one single variable
called `names`, which is not what was meant.

## 2. Quotes — why almost everything is wrapped in `"..."`

```bash
greeting="Hello there"
```

Double quotes let a variable hold text with spaces in it, and they also
let you put `$other_variables` INSIDE the quotes and have them still work:

```bash
echo "Hello, $name, welcome!"
```

Single quotes (`'...'`) are different: they mean "treat this text
completely literally, don't look for any `$variables` inside it." You'll
see single quotes used for things like search patterns where a `$` sign
needs to be treated as a literal character rather than "the start of a
variable."

## 3. Comments — notes for humans, ignored by the computer

```bash
# This whole line is a comment. The computer skips it entirely.
name="Bob"  # you can also put a comment after real code, like this
```

Anything after a `#` is a note for the human reading the file — it has
zero effect on what the program does. Every file in this project uses
comments heavily to explain *why* something is written the way it is.

## 4. Running a program and capturing what it prints

```bash
current_date="$(date)"
```

The `$( ... )` wrapper means: *"run the command inside the parentheses,
and whatever it prints out, store that as text in the variable."* This is
one of the most common patterns in this codebase — running a real Linux
command (`date`, `curl`, `systemctl status`, etc.) and capturing its
output to inspect or reuse later.

## 5. If/then/else — making a decision

```bash
if [[ -n "$name" ]]; then
    echo "Name was provided: $name"
else
    echo "No name was given."
fi
```

Plain English: *"if this condition is true, do the first thing; otherwise,
do the second thing."* `fi` (if spelled backwards) marks the end of the
if-statement — Bash needs an explicit "this is where it ends" marker
since, unlike some languages, it doesn't use indentation to know where a
block of code stops.

Common conditions you'll see inside the `[[ ... ]]` brackets:
| Written as | Means |
|---|---|
| `-n "$x"` | "the variable `x` is NOT empty" |
| `-z "$x"` | "the variable `x` IS empty" |
| `"$x" == "$y"` | "`x` and `y` are equal" |
| `"$x" != "$y"` | "`x` and `y` are NOT equal" |
| `-f "$path"` | "a regular file exists at this path" |
| `-d "$path"` | "a folder (directory) exists at this path" |
| `-x "$path"` | "a file exists at this path AND is executable" |

## 6. Functions — giving a group of instructions a name

```bash
say_hello() {
    echo "Hello, $1!"
}
```

This defines a reusable block of instructions called `say_hello`. Nothing
happens yet — defining a function is like writing a recipe, not cooking
it. To actually run it:

```bash
say_hello "Bob"
```

Inside a function, `$1` means "the first thing that was passed in when it
was called" (here, `"Bob"`), `$2` would be the second thing, and so on.
This project's functions almost always have a one-line `#` comment
directly above them explaining, in plain English, what they do and why.

## 7. Loops — repeating an action for each item in a list

```bash
for name in Alice Bob Carol; do
    echo "Hello, $name"
done
```

This runs the `echo` line three times, once for each name. `done` marks
where the loop ends (matching `for...do` the same way `fi` matches `if`).

You'll also see this style, which reads a command's output one line at a
time:

```bash
while IFS= read -r line; do
    echo "Got a line: $line"
done < <(some_command)
```

Plain English: *"run `some_command`, and for each line it prints out, put
that line into the variable called `line` and run the loop body once."*
This is how the code processes things like "every registered game server
instance" or "every port a game needs" — one at a time, from a list that
some other command produced.

## 8. Arrays — a list stored in one variable

```bash
fruits=("apple" "banana" "cherry")
echo "${fruits[0]}"        # prints: apple  (counting starts at 0, not 1!)
echo "${fruits[@]}"        # prints all of them: apple banana cherry
fruits+=("date")           # adds "date" to the end of the list
```

This project uses arrays heavily for **the list of command-line options
to launch a game server with** — building up exactly which words and
settings to hand to the actual game program before starting it.

## 9. Exit codes — how a command reports "it worked" or "it failed"

Every command that finishes in Linux reports back a number: `0` always
means "success," and any other number (usually `1`) means "something went
wrong." You'll see this checked explicitly:

```bash
if curl -fsS "https://example.com" > /dev/null; then
    echo "The website responded."
else
    echo "The website did not respond."
fi
```

And you'll see `set -e` near the top of the bigger files — this is a
blanket instruction meaning *"if ANY command in this whole script fails
(reports a non-zero exit code) and nothing is explicitly checking for
that failure, stop the entire script immediately rather than blindly
continuing."* It's a safety net against a small problem silently causing
a much bigger, confusing mess further down the script.

## 10. Redirection — sending output somewhere other than the screen

```bash
echo "hello" > file.txt      # writes "hello" into file.txt (erasing whatever was there before)
echo "hello" >> file.txt     # ADDS "hello" to the end of file.txt, keeping what was already there
some_command 2>&1            # combine "normal output" and "error output" into a single stream
some_command > /dev/null     # throw the output away entirely (/dev/null is a real, special file that always discards everything written to it)
```

## 11. Heredocs — writing several lines of text at once

```bash
cat > settings.txt << EOF
line one
line two, and $variables inside a heredoc DO get replaced with their value
EOF
```

This is how almost every config file in this project gets created: rather
than writing many separate `echo "..." >> file` lines, a single block
between `<< EOF` and the matching `EOF` is written to the file all at
once, with any `$variables` inside it automatically filled in.

## 12. Putting it together — a real, annotated example from this project

Here's an actual line from `terraria.profile.sh`, explained piece by
piece:

```bash
prompt_and_validate "World name" "MyWorld" validate_generic_safe_string TR_WORLD_NAME 0
```

- `prompt_and_validate` — call the function with this name (defined once,
  in the main script, and reused by every game).
- `"World name"` — the first piece of information handed to that
  function: the question to show the person setting up the server.
- `"MyWorld"` — the second piece: the default answer to use if they just
  press Enter.
- `validate_generic_safe_string` — the third piece: the NAME of another
  function to use for checking the answer is safe/sensible before
  accepting it.
- `TR_WORLD_NAME` — the fourth piece: the name of the variable to store
  the final answer in.
- `0` — the fifth piece: a plain flag meaning "this is not a secret
  password, it's fine to show what's typed on screen."

---

## A note on this project's specific vocabulary

- **"Instance" / "shard"** — one running copy of a game server (you can
  run several at once, even of different games, on one computer).
- **"Profile"** — the one file that tells the platform everything specific
  to one game (Minecraft, Rust, etc.) — see `PROFILE-AUTHORING.md`.
- **systemd / `systemctl`** — the part of Linux responsible for starting,
  stopping, and automatically restarting background programs (like a
  game server) even after the computer reboots.
- **SteamCMD** — a command-line tool, made by Valve (the company behind
  Steam), for downloading a game's server files without needing the full
  Steam graphical app.

If a specific line still doesn't make sense after reading this guide,
every function in every file has its own comment directly above it
explaining what it does in plain English — that's the next place to look.
