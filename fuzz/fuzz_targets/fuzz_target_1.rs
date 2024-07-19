#![no_main]

use libfuzzer_sys::fuzz_target;

use mktemp::Temp;
use std::fs;
use lalrpop::Configuration;

fuzz_target!(|data: &[u8]| {
    let temp_file = Temp::new_file().unwrap();
    fs::write(temp_file.as_path(), data).unwrap();

    let _ = Configuration::new().process_file(temp_file);

});
