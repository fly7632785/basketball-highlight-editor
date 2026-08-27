use std::io::{self, Read};

fn main() {
    let mut input = String::new();
    io::stdin()
        .read_to_string(&mut input)
        .expect("read request");
    let replay = std::env::args()
        .skip(1)
        .any(|arg| arg == "--decision-replay");
    let result = if replay {
        bhe_runtime::evaluate_decision_replay_json(&input)
    } else {
        bhe_runtime::analyze_json(&input)
    };
    match result {
        Ok(output) => println!("{output}"),
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    }
}
