use std::env;
use std::fs;
use std::time::Instant;

use lol_html::{HtmlRewriter, Settings};

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() != 3 {
        eprintln!("usage: {} <html-file> <iterations>", args[0]);
        std::process::exit(2);
    }

    let input = fs::read(&args[1]).expect("failed to read html file");
    let iterations: usize = args[2].parse().expect("invalid iterations");

    let start = Instant::now();
    for _ in 0..iterations {
        let mut rewriter = HtmlRewriter::new(Settings::new(), |chunk: &[u8]| {
            std::hint::black_box(chunk);
        });
        rewriter.write(&input).expect("rewriter write failed");
        rewriter.end().expect("rewriter end failed");
    }
    let total_ns = start.elapsed().as_nanos();
    println!("{}", total_ns);
}
