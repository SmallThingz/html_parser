use std::env;
use std::fs;
use std::time::Instant;

use html5ever::driver::ParseOpts;
use html5ever::parse_document;
use html5ever::tendril::TendrilSink;
use markup5ever_rcdom::RcDom;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: {} <html-file> <iterations>", args[0]);
        std::process::exit(2);
    }

    let input = fs::read_to_string(&args[1]).expect("failed to read html file");
    let iterations: usize = args[2].parse().expect("invalid iterations");
    let input_ref = input.as_str();

    let start = Instant::now();
    for _ in 0..iterations {
        let _dom: RcDom = parse_document(RcDom::default(), ParseOpts::default()).one(input_ref);
    }
    let total_ns = start.elapsed().as_nanos();
    println!("{}", total_ns);
}
