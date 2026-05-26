version 1.0

task reverse_line {
  input {
    String line
  }
  
  command {
    echo "${line}" | rev
  }
  
  output {
    String reversed = read_string(stdout())
  }
  
  runtime {
    docker: "ubuntu:25.10"
  }
}

workflow reverse_lines_workflow {
  input {
    File input_file
  }
  
  # Read all lines from the input file
  Array[String] lines = read_lines(input_file)
  
  # Scatter: process each line in parallel
  scatter (line in lines) {
    call reverse_line {
      input: line = line
    }
  }
  
  output {
    Array[String] reversed_lines = reverse_line.reversed
  }
}

