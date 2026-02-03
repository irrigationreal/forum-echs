//! Rust NIF for shell command parsing and safety validation.
//!
//! This module provides functions to parse shell commands using tree-sitter-bash
//! and validate that they don't contain unsafe constructs.

use rustler::Atom;
use tree_sitter::{Node, Parser, Tree};
use tree_sitter_bash::LANGUAGE as BASH;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        unsafe_construct,
        parse_error,
    }
}

/// Parse the provided bash source using tree-sitter-bash.
fn try_parse_shell(script: &str) -> Option<Tree> {
    let lang = BASH.into();
    let mut parser = Parser::new();
    parser.set_language(&lang).ok()?;
    parser.parse(script, None)
}

/// Parse a script which may contain multiple simple commands joined only by
/// safe operators: `&&`, `||`, `;`, `|`.
///
/// Returns `Some(Vec<command_words>)` if every command is a plain word-only
/// command and the parse tree does not contain disallowed constructs.
fn try_parse_word_only_commands_sequence(tree: &Tree, src: &str) -> Option<Vec<Vec<String>>> {
    if tree.root_node().has_error() {
        return None;
    }

    // List of allowed (named) node kinds for a "word only commands sequence".
    const ALLOWED_KINDS: &[&str] = &[
        // top level containers
        "program",
        "list",
        "pipeline",
        // commands & words
        "command",
        "command_name",
        "word",
        "string",
        "string_content",
        "raw_string",
        "number",
        "concatenation",
    ];

    // Allow only safe punctuation / operator tokens.
    const ALLOWED_PUNCT_TOKENS: &[&str] = &["&&", "||", ";", "|", "\"", "'"];

    let root = tree.root_node();
    let mut cursor = root.walk();
    let mut stack = vec![root];
    let mut command_nodes = Vec::new();

    while let Some(node) = stack.pop() {
        let kind = node.kind();
        if node.is_named() {
            if !ALLOWED_KINDS.contains(&kind) {
                return None;
            }
            if kind == "command" {
                command_nodes.push(node);
            }
        } else {
            // Reject any punctuation / operator tokens that are not explicitly allowed.
            if kind.chars().any(|c| "&;|".contains(c)) && !ALLOWED_PUNCT_TOKENS.contains(&kind) {
                return None;
            }
            if !(ALLOWED_PUNCT_TOKENS.contains(&kind) || kind.trim().is_empty()) {
                return None;
            }
        }
        for child in node.children(&mut cursor) {
            stack.push(child);
        }
    }

    // Walk uses a stack (LIFO), so re-sort by position to restore source order.
    command_nodes.sort_by_key(Node::start_byte);

    let mut commands = Vec::new();
    for node in command_nodes {
        if let Some(words) = parse_plain_command_from_node(node, src) {
            commands.push(words);
        } else {
            return None;
        }
    }
    Some(commands)
}

fn parse_plain_command_from_node(cmd: Node, src: &str) -> Option<Vec<String>> {
    if cmd.kind() != "command" {
        return None;
    }
    let mut words = Vec::new();
    let mut cursor = cmd.walk();

    for child in cmd.named_children(&mut cursor) {
        match child.kind() {
            "command_name" => {
                let word_node = child.named_child(0)?;
                if word_node.kind() != "word" {
                    return None;
                }
                words.push(word_node.utf8_text(src.as_bytes()).ok()?.to_owned());
            }
            "word" | "number" => {
                words.push(child.utf8_text(src.as_bytes()).ok()?.to_owned());
            }
            "string" => {
                if child.child_count() == 3
                    && child.child(0)?.kind() == "\""
                    && child.child(1)?.kind() == "string_content"
                    && child.child(2)?.kind() == "\""
                {
                    words.push(child.child(1)?.utf8_text(src.as_bytes()).ok()?.to_owned());
                } else {
                    return None;
                }
            }
            "raw_string" => {
                let raw_string = child.utf8_text(src.as_bytes()).ok()?;
                let stripped = raw_string
                    .strip_prefix('\'')
                    .and_then(|s| s.strip_suffix('\''));
                if let Some(s) = stripped {
                    words.push(s.to_owned());
                } else {
                    return None;
                }
            }
            "concatenation" => {
                // Handle concatenated arguments like -g"*.py"
                let mut concatenated = String::new();
                let mut concat_cursor = child.walk();
                for part in child.named_children(&mut concat_cursor) {
                    match part.kind() {
                        "word" | "number" => {
                            concatenated.push_str(part.utf8_text(src.as_bytes()).ok()?);
                        }
                        "string" => {
                            if part.child_count() == 3
                                && part.child(0)?.kind() == "\""
                                && part.child(1)?.kind() == "string_content"
                                && part.child(2)?.kind() == "\""
                            {
                                concatenated.push_str(
                                    part.child(1)?.utf8_text(src.as_bytes()).ok()?,
                                );
                            } else {
                                return None;
                            }
                        }
                        "raw_string" => {
                            let raw_string = part.utf8_text(src.as_bytes()).ok()?;
                            let stripped = raw_string
                                .strip_prefix('\'')
                                .and_then(|s| s.strip_suffix('\''))?;
                            concatenated.push_str(stripped);
                        }
                        _ => return None,
                    }
                }
                if concatenated.is_empty() {
                    return None;
                }
                words.push(concatenated);
            }
            _ => return None,
        }
    }
    Some(words)
}

/// Result type for parse_shell_commands NIF.
pub enum ParseResult {
    Ok(Vec<Vec<String>>),
    Error(Atom),
}

impl rustler::Encoder for ParseResult {
    fn encode<'a>(&self, env: rustler::Env<'a>) -> rustler::Term<'a> {
        match self {
            ParseResult::Ok(commands) => (atoms::ok(), commands).encode(env),
            ParseResult::Error(reason) => (atoms::error(), *reason).encode(env),
        }
    }
}

/// NIF: Parse shell commands from a script string.
///
/// Returns `{:ok, commands}` or `{:error, reason}`.
#[rustler::nif]
fn parse_shell_commands(script: String) -> ParseResult {
    let tree = match try_parse_shell(&script) {
        Some(t) => t,
        None => return ParseResult::Error(atoms::parse_error()),
    };

    match try_parse_word_only_commands_sequence(&tree, &script) {
        Some(commands) => ParseResult::Ok(commands),
        None => ParseResult::Error(atoms::unsafe_construct()),
    }
}

/// Safe commands that are read-only and don't modify system state.
const SAFE_COMMANDS: &[&str] = &[
    "cat", "cd", "cut", "echo", "expr", "false", "grep", "head", "id", "ls", "nl", "paste", "pwd",
    "rev", "seq", "stat", "tail", "tr", "true", "uname", "uniq", "wc", "which", "whoami",
    // Linux-specific
    "numfmt", "tac",
];

/// Commands that are safe with certain restrictions.
fn is_safe_with_restrictions(command: &[String]) -> bool {
    let Some(cmd0) = command.first().map(String::as_str) else {
        return false;
    };

    let cmd_name = std::path::Path::new(cmd0)
        .file_name()
        .and_then(|osstr| osstr.to_str())
        .unwrap_or(cmd0);

    match cmd_name {
        "base64" => {
            const UNSAFE_BASE64_OPTIONS: &[&str] = &["-o", "--output"];
            !command.iter().skip(1).any(|arg| {
                UNSAFE_BASE64_OPTIONS.contains(&arg.as_str())
                    || arg.starts_with("--output=")
                    || (arg.starts_with("-o") && arg != "-o")
            })
        }
        "find" => {
            const UNSAFE_FIND_OPTIONS: &[&str] = &[
                "-exec", "-execdir", "-ok", "-okdir", "-delete", "-fls", "-fprint", "-fprint0",
                "-fprintf",
            ];
            !command
                .iter()
                .any(|arg| UNSAFE_FIND_OPTIONS.contains(&arg.as_str()))
        }
        "rg" => {
            const UNSAFE_RG_WITH_ARGS: &[&str] = &["--pre", "--hostname-bin"];
            const UNSAFE_RG_FLAGS: &[&str] = &["--search-zip", "-z"];
            !command.iter().any(|arg| {
                UNSAFE_RG_FLAGS.contains(&arg.as_str())
                    || UNSAFE_RG_WITH_ARGS
                        .iter()
                        .any(|&opt| arg == opt || arg.starts_with(&format!("{opt}=")))
            })
        }
        "git" => matches!(
            command.get(1).map(String::as_str),
            Some("branch" | "status" | "log" | "diff" | "show")
        ),
        "cargo" => command.get(1).map(String::as_str) == Some("check"),
        "sed" => {
            command.len() <= 4
                && command.get(1).map(String::as_str) == Some("-n")
                && is_valid_sed_n_arg(command.get(2).map(String::as_str))
        }
        _ => false,
    }
}

/// Returns true if `arg` matches /^(\d+,)?\d+p$/
fn is_valid_sed_n_arg(arg: Option<&str>) -> bool {
    let Some(s) = arg else { return false };
    let Some(core) = s.strip_suffix('p') else {
        return false;
    };
    let parts: Vec<&str> = core.split(',').collect();
    match parts.as_slice() {
        [num] => !num.is_empty() && num.chars().all(|c| c.is_ascii_digit()),
        [a, b] => {
            !a.is_empty()
                && !b.is_empty()
                && a.chars().all(|c| c.is_ascii_digit())
                && b.chars().all(|c| c.is_ascii_digit())
        }
        _ => false,
    }
}

fn is_safe_to_call_with_exec(command: &[String]) -> bool {
    let Some(cmd0) = command.first().map(String::as_str) else {
        return false;
    };

    let cmd_name = std::path::Path::new(cmd0)
        .file_name()
        .and_then(|osstr| osstr.to_str())
        .unwrap_or(cmd0);

    if SAFE_COMMANDS.contains(&cmd_name) {
        return true;
    }

    is_safe_with_restrictions(command)
}

/// NIF: Check if a command is known to be safe (read-only).
#[rustler::nif]
fn is_safe_command(command: Vec<String>) -> bool {
    if is_safe_to_call_with_exec(&command) {
        return true;
    }

    // Support `bash -lc "..."` where the script consists solely of safe commands.
    if let Some(script) = extract_bash_script(&command) {
        if let Some(tree) = try_parse_shell(script) {
            if let Some(all_commands) = try_parse_word_only_commands_sequence(&tree, script) {
                if !all_commands.is_empty()
                    && all_commands
                        .iter()
                        .all(|cmd| is_safe_to_call_with_exec(cmd))
                {
                    return true;
                }
            }
        }
    }

    false
}

fn extract_bash_script(command: &[String]) -> Option<&str> {
    if command.len() != 3 {
        return None;
    }
    let (shell, flag, script) = (&command[0], &command[1], &command[2]);

    if !matches!(flag.as_str(), "-lc" | "-c") {
        return None;
    }

    let shell_name = std::path::Path::new(shell)
        .file_name()
        .and_then(|osstr| osstr.to_str())
        .unwrap_or(shell);

    if !matches!(shell_name, "bash" | "zsh" | "sh") {
        return None;
    }

    Some(script.as_str())
}

rustler::init!("Elixir.EchsBashParser");
