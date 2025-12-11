Docs
Guides
Components
Download
Blog
Support
Observability Pipelines
Toggle dark mode
Search

Search
Twitter icon and link
GitHub icon and link
Chat icon and link
RSS icon and link
Docs home
Introduction
Concepts
Setup
Quickstart
Installation
Deployment
Going to Production
Architecture
Data model
Pipeline model
Runtime model
Buffering model
Concurrency model
Adaptive Concurrency
Guarantees
End-to-end Acknowledgements
Administration
Management
Monitoring
Validating
Optimization
Reference
Vector Remap Language
Configuration
CLI
Environment Variables
API
Glossary
Meta

Security

Releases

Versioning

Vector
Docs home
Reference
Vector Remap Language
Vector Remap Language (VRL)
A domain-specific language for modifying your observability data

Vector Remap Language (VRL) is an expression-oriented language designed for transforming observability data (logs and metrics) in a safe and performant manner. It features a simple syntax and a rich set of built-in functions tailored specifically to observability use cases.

You can use VRL in Vector via the remap transform. For a more in-depth picture, see the announcement blog post.

Quickstart
VRL programs act on a single observability event and can be used to:

Transform observability events
Specify conditions for routing and filtering events
Those programs are specified as part of your Vector configuration. Here’s an example remap transform that contains a VRL program in the source field:

vector.yaml
transforms:
  modify:
    type: remap
    inputs:
      - logs
    source: |
      del(.user_info)
      .timestamp = now()      
This program changes the contents of each event that passes through this transform, deleting the user_info field and adding a timestamp to the event.

Example: parsing JSON
Let’s have a look at a more complex example. Imagine that you’re working with HTTP log events that look like this:

{
  "message": "{\"status\":200,\"timestamp\":\"2021-03-01T19:19:24.646170Z\",\"message\":\"SUCCESS\",\"username\":\"ub40fan4life\"}"
}
Let’s assume you want to apply a set of changes to each event that arrives to your Remap transform in order to produce an event with the following fields:

message (string)
status (int)
timestamp (int)
timestamp_str (timestamp)
The following VRL program demonstrates how to achieve the above:

# Parse the raw string into a JSON object, this way we can manipulate fields.
. = parse_json!(string!(.message))

# At this point `.` is the following:
#{
#  "message": "SUCCESS",
#  "status": 200,
#  "timestamp": "2021-03-01T19:19:24.646170Z",
#  "username": "ub40fan4life"
#}

# Attempt to parse the timestamp that was in the original message.
# Note that `.timestamp` can be `null` if it wasn't present.
parsed_timestamp, err = parse_timestamp(.timestamp, format: "%Y-%m-%dT%H:%M:%S.%fZ")

# Check if the conversion was successful. Note here that all errors must be handled, more on that later.
if err == null {
   # Note that the `to_unix_timestamp` expects a `timestamp` argument.
   # The following will compile because `parse_timestamp` returns a `timestamp`.
  .timestamp = to_unix_timestamp(parsed_timestamp)
} else {
  # Conversion failed, in this case use the current time.
  .timestamp = to_unix_timestamp(now())
}

# Convert back to timestamp for this tutorial.
.timestamp_str = from_unix_timestamp!(.timestamp)

# Remove the `username` field from the final target.
del(.username)

# Convert the `message` to lowercase.
.message = downcase(string!(.message))
Finally, the resulting event:

{
  "message": "success",
  "status": 200,
  "timestamp": 1614644364,
  "timestamp_str": "2021-03-02T00:19:24Z"
}
Example: filtering events
The JSON parsing program in the example above modifies the contents of each event. But you can also use VRL to specify conditions, which convert events into a single Boolean expression. Here’s an example filter transform that filters out all messages for which the severity field equals "info":

vector.yaml
transforms:
  filter_out_info:
    type: filter
    inputs:
      - logs
    condition: '.severity != "info"'
Conditions can also be more multifaceted. This condition would filter out all events for which the severity field is "info", the status_code field is greater than or equal to 400, and the host field isn’t set:

condition = '.severity != "info" && .status_code < 400 && exists(.host)'
More VRL examples
You can find more VRL examples further down on this page or in the VRL example reference.
Reference
All language constructs are contained in the following reference pages. Use these references as you write your VRL programs:

Functions
Errors
Examples
Expressions
Learn
VRL is designed to minimize the learning curve. These resources can help you get acquainted with Vector and VRL:

Vector quickstart
Structuring, Shaping, and Transforming Data
VRL playground
There is an online VRL playground, where you can experiment with VRL.

Some functions are currently unsupported on the playground. Functions that are currently not supported can be found with this issue filter

The goals of VRL
VRL is built by the Vector team and its development is guided by two core goals, safety and performance, without compromising on flexibility. This makes VRL ideal for critical, performance-sensitive infrastructure, like observability pipelines. To illustrate how we achieve these, below is a VRL feature matrix across these principles:

Feature	Safety	Performance
Compilation	✅	✅
Ergonomic safety	✅	✅
Fail safety	✅	
Memory safety	✅	
Vector and Rust native	✅	✅
Statelessness	✅	✅
Concepts
VRL has some core concepts that you should be aware of as you dive in.

Assertions
VRL offers two functions that you can use to assert that VRL values conform to your expectations: assert and assert_eq. assert aborts the VRL program and logs an error if the provided Boolean expression evaluates to false, while assert_eq fails logs an error if the provided values aren’t equal. Both functions also enable you to provide custom log messages to be emitted upon failure.

When running Vector, assertions can be useful in situations where you need to be notified when any observability event fails a condition. When writing unit tests, assertions can provide granular insight into which test conditions have failed and why.

Boolean expressions
In VRL, Boolean expressions resolve to a single Boolean value (either true or false). Boolean expressions can be of any complexity and have several uses in Vector, including specifying conditions for routing and filtering events.
Event
VRL programs operate on observability events. This VRL program, for example, adds a field to a log event:

.new_field = "new value"
The event at hand, represented by ., is the entire context of the VRL program.

The event can be set to a value other than an object, for example . = 5. If it is set to an array, each element of that array is emitted as its own event from the remap transform. For any elements that aren’t an object, or if the top-level . is set to a scalar value, that value is set as the message key on the emitted object.

This expression, for example…

. = ["hello", 1, true, { "foo": "bar" }]
…results in these four events being emitted:

{ "message": "hello" }
{ "message": 1 }
{ "message": true }
{ "foo": "bar" }
Characteristics
Paths
Path expressions enable you to access values inside the event:

.kubernetes.pod_id
Expressions
VRL is an expression-oriented language. A VRL program consists entirely of expressions, with every expression returning a value.
Function
Like most languages, VRL includes functions that represent named procedures designed to accomplish specific tasks. Functions are the highest-level construct of reusable code in VRL, which, for the sake of simplicity, doesn’t include modules, classes, or other complex constructs for organizing functions.
Characteristics
Deprecation
VRL functions can be marked as “deprecated”. When a function is deprecated, a warning will be shown at runtime.

Suggestions on how to update the VRL program can usually be found in the actual warning and the function documentation.

Fallibility
Some VRL functions are fallible, meaning that they can error. Any potential errors thrown by fallible functions must be handled, a requirement enforced at compile time.

This feature of VRL programs, which we call fail safety, is a defining characteristic of VRL and a primary source of its safety guarantees.

Literal
As in most other languages, literals in VRL are values written exactly as they are meant to be interpreted. Literals include things like strings, Booleans, and integers.
Transforming metrics
VRL enables you to transform log events with very few restrictions but is much more restrictive when it comes to how you can transform metrics. See the event data model documentation for a field-by-field breakdown of changes you can and can’t make to metric events.
Program
A VRL program is the highest-level unit of computation. A program is the end result of combining an arbitrary number of expressions operating on a single observability event.
Features
Compilation
VRL programs are compiled to and run as native Rust code. This has several important implications:

VRL programs are extremely fast and efficient, with performance characteristics very close to Rust itself
VRL has no runtime and thus imposes no per-event foreign function interface (FFI) or data conversion costs
VRL has no garbage collection, which means no GC pauses and no accumulated memory usage across events
Characteristics
Fail safety checks
At compile time, Vector performs fail safety checks to ensure that all errors thrown by fallible functions are handled. If you fail to pass a string to the parse_syslog function, for example, the VRL compiler aborts and provides a helpful error message. Fail safety means that you need to make explicit decisions about how to handle potentially malformed data—a superior alternative to being surprised by such issues when Vector is already handling your data in production.
Type safety checks
At compile time, Vector performs type safety) checks to catch runtime errors stemming from type mismatches, for example passing an integer to the parse_syslog function, which can only take a string. VRL essentially forces you to write programs around the assumption that every incoming event could be malformed, which provides a strong bulwark against both human error and also the many potential consequences of malformed data.
Ergonomic safety
VRL is ergonomically safe in that it makes it difficult to create slow or buggy VRL programs. While VRL’s compile-time checks prevent runtime errors, they can’t prevent some of the more elusive performance and maintainability problems that stem from program complexity—problems that can result in observability pipeline instability and unexpected resource costs. To protect against these more subtle ergonomic problems, VRL is a carefully limited language that offers only those features necessary to transform observability data. Any features that are extraneous to that task or likely to result in degraded ergonomics are omitted from the language by design.
Characteristics
Internal logging limitation
VRL programs do produce internal logs but not a rate that’s bound to saturate I/O.
I/O limitation
VRL lacks access to system I/O, which tends to be computationally expensive, to require careful caching, and to produce degraded performance.
Lack of custom functions
VRL requires you to use only its built-in functions and doesn’t enable you to create your own. This keeps VRL programs easy to debug and reason about.
Purpose built for observability
VRL is laser focused on observability use cases and only those use cases. This makes many frustration- and complexity-producing constructs you find in other languages completely superfluous. Functions like parse_syslog and parse_key_value, for example, make otherwise complex tasks simple and prevent the need for complex low-level constructs.
Rate-limited logging
The VRL log function implements rate limiting by default. This ensures that VRL programs invoking the log method don’t accidentally saturate I/O.
Lack of recursion
VRL lacks recursion capabilities, making it impossible to create large or infinite loops that could stall VRL programs or needlessly drain memory.
Lack of state
VRL lacks the ability to hold and maintain state across events. This prevents things like unbounded memory growth, hard-to-debug production issues, and unexpected program behavior.
Fail safety
VRL programs are fail safe, meaning that a VRL program won’t compile unless all errors thrown by fallible functions are handled. This eliminates unexpected runtime errors that often plague production observability pipelines with data loss and downtime. See the error reference for more information on VRL errors.
High-quality error messages
VRL strives to provide high-quality, helpful error messages, streamlining the development and iteration workflow around VRL programs.

This VRL program, for example…

parse_json!(1)
…would result in this error:

error[E110]: invalid argument type
  ┌─ :2:13
  │
2 │ parse_json!(1)
  │             ^
  │             │
  │             this expression resolves to the exact type integer
  │             but the parameter "value" expects the exact type string
  │
  = try: ensuring an appropriate type at runtime
  =
  =     1 = string!(1)
  =     parse_json!(1)
  =
  = try: coercing to an appropriate type and specifying a default value as a fallback in case coercion fails
  =
  =     1 = to_string(1) ?? "default"
  =     parse_json!(1)
  =
  = see documentation about error handling at https://errors.vrl.dev/#handling
  = learn more about error code 110 at https://errors.vrl.dev/110
  = see language documentation at https://vrl.dev
  = try your code in the VRL REPL, learn more at https://vrl.dev/examples
Logs and metrics
VRL works with both logs and metrics within Vector, making it usable for all Vector events.
Memory safety
VRL inherits Rusts’s memory safety guarantees, protecting you from common software bugs and security vulnerabilities that stem from improper memory access. This makes VRL ideal for infrastructure use cases, like observability pipelines, where reliability and security are top concerns.
Vector & Rust native
Like Vector, VRL is built with Rust and compiles to native Rust code. Therefore, it inherits Rust’s safety and performance characteristics that make it ideal for observability pipelines. And because both VRL and Vector are written in Rust, they are tightly integrated, avoiding communication inefficiencies such as event serialization or foreign function interfaces (FFI). This makes VRL significantly faster than non-Rust alternatives.
Characteristics
Lack of garbage collection
Rust’s affine type system avoids the need for garbage collection, making VRL exceptionally fast, memory efficient, and memory safe. Memory is precisely allocated and freed, avoiding the pauses and performance pitfalls associated with garbage collectors.
Stateless
VRL programs are stateless, operating on a single event at a time. This makes VRL programs simple, fast, and safe. Operations involving state across events, such as deduplication, are delegated to other Vector transforms designed specifically for stateful operations.
Type safety
VRL implements progressive type safety, erroring at compilation-time if a type mismatch is detected.
Characteristics
Progressive type safety
VRL’s type-safety is progressive, meaning it will implement type-safety for any value for which it knows the type. Because observability data can be quite unpredictable, it’s not always known which type a field might be, hence the progressive nature of VRL’s type-safety. As VRL scripts are evaluated, type information is built up and used at compile-time to enforce type-safety. Let’s look at an example:

.foo # any
.foo = downcase!(.foo) # string
.foo = upcase(.foo) # string
Breaking down the above:

The .foo field starts off as an any type (AKA unknown).
The call to the downcase! function requires error handling (!) since VRL cannot guarantee that .foo is a string (the only type supported by downcase).
Afterwards, assuming the downcase invocation is successful, VRL knows that .foo is a string, since downcase can only return strings.
Finally, the call to upcase does not require error handling (!) since VRL knows that .foo is a string, making the upcase invocation infallible.
To avoid error handling for argument errors, you can specify the types of your fields at the top of your VRL script:

.foo = string!(.foo) # string

.foo = downcase(.foo) # string
This is generally good practice, and it provides the ability to opt-into type safety as you see fit, VRL scripts are written once and evaluated many times, therefore the tradeoff for type safety will ensure reliable production execution.

Principles
Performance
VRL is implemented in the very fast and efficient Rust language and VRL scripts are compiled into Rust code when Vector is started. This means that you can use VRL to transform observability data with a minimal per-event performance penalty vis-à-vis pure Rust. In addition, ergonomic features such as compile-time correctness checks and the lack of language constructs like loops make it difficult to write scripts that are slow or buggy or require optimization.
Safety
VRL is a safe language in several senses: VRL scripts have access only to the event data that they handle and not, for example, to the Internet or the host; VRL provides the same strong memory safety guarantees as Rust; and, as mentioned above, compile-time correctness checks prevent VRL scripts from behaving in unexpected or sub-optimal ways. These factors distinguish VRL from other available event data transformation languages and runtimes.
Other examples
Parse Syslog logs
Given this Vector log event...
{
  "message": "\u003c102\u003e1 2020-12-22T15:22:31.111Z vector-user.biz su 2666 ID389 - Something went wrong"
}
...and this VRL program...
. |= parse_syslog!(.message)
...the following log event is output:
{
  "log": {
    "appname": "su",
    "facility": "ntp",
    "hostname": "vector-user.biz",
    "message": "Something went wrong",
    "msgid": "ID389",
    "procid": 2666,
    "severity": "info",
    "timestamp": "2020-12-22T15:22:31.111Z",
    "version": 1
  }
}
Parse key/value (logfmt) logs
Given this Vector log event...
{
  "message": "@timestamp=\"Sun Jan 10 16:47:39 EST 2021\" level=info msg=\"Stopping all fetchers\" tag#production=stopping_fetchers id=ConsumerFetcherManager-1382721708341 module=kafka.consumer.ConsumerFetcherManager"
}
...and this VRL program...
. = parse_key_value!(.message)
...the following log event is output:
{
  "log": {
    "@timestamp": "Sun Jan 10 16:47:39 EST 2021",
    "id": "ConsumerFetcherManager-1382721708341",
    "level": "info",
    "module": "kafka.consumer.ConsumerFetcherManager",
    "msg": "Stopping all fetchers",
    "tag#production": "stopping_fetchers"
  }
}
Parse custom logs
Given this Vector log event...
{
  "message": "2021/01/20 06:39:15 +0000 [error] 17755#17755: *3569904 open() \"/usr/share/nginx/html/test.php\" failed (2: No such file or directory), client: xxx.xxx.xxx.xxx, server: localhost, request: \"GET /test.php HTTP/1.1\", host: \"yyy.yyy.yyy.yyy\""
}
...and this VRL program...
. |= parse_regex!(.message, r'^(?P<timestamp>\d+/\d+/\d+ \d+:\d+:\d+ \+\d+) \[(?P<severity>\w+)\] (?P<pid>\d+)#(?P<tid>\d+):(?: \*(?P<connid>\d+))? (?P<message>.*)$')

# Coerce parsed fields
.timestamp = parse_timestamp(.timestamp, "%Y/%m/%d %H:%M:%S %z") ?? now()
.pid = to_int!(.pid)
.tid = to_int!(.tid)

# Extract structured data
message_parts = split(.message, ", ", limit: 2)
structured = parse_key_value(message_parts[1], key_value_delimiter: ":", field_delimiter: ",") ?? {}
.message = message_parts[0]
. = merge(., structured)
...the following log event is output:
{
  "log": {
    "client": "xxx.xxx.xxx.xxx",
    "connid": "3569904",
    "host": "yyy.yyy.yyy.yyy",
    "message": "open() \"/usr/share/nginx/html/test.php\" failed (2: No such file or directory)",
    "pid": 17755,
    "request": "GET /test.php HTTP/1.1",
    "server": "localhost",
    "severity": "error",
    "tid": 17755,
    "timestamp": "2021-01-20T06:39:15Z"
  }
}
Multiple parsing strategies
Given this Vector log event...
{
  "message": "\u003c102\u003e1 2020-12-22T15:22:31.111Z vector-user.biz su 2666 ID389 - Something went wrong"
}
...and this VRL program...
structured =
  parse_syslog(.message) ??
  parse_common_log(.message) ??
  parse_regex!(.message, r'^(?P<timestamp>\d+/\d+/\d+ \d+:\d+:\d+) \[(?P<severity>\w+)\] (?P<pid>\d+)#(?P<tid>\d+):(?: \*(?P<connid>\d+))? (?P<message>.*)$')
. = merge(., structured)
...the following log event is output:
{
  "log": {
    "appname": "su",
    "facility": "ntp",
    "hostname": "vector-user.biz",
    "message": "Something went wrong",
    "msgid": "ID389",
    "procid": 2666,
    "severity": "info",
    "timestamp": "2020-12-22T15:22:31.111Z",
    "version": 1
  }
}
Modify metric tags
Given this Vector metric event...
{
  "counter": {
    "value": 102
  },
  "kind": "incremental",
  "name": "user_login_total",
  "tags": {
    "email": "vic@vector.dev",
    "host": "my.host.com",
    "instance_id": "abcd1234"
  }
}
...and this VRL program...
.tags.environment = get_env_var!("ENV") # add
.tags.hostname = del(.tags.host) # rename
del(.tags.email)
...the following metric event is output:
{
  "metric": {
    "counter": {
      "value": 102
    },
    "kind": "incremental",
    "name": "user_login_total",
    "tags": {
      "environment": "production",
      "hostname": "my.host.com",
      "instance_id": "abcd1234"
    }
  }
}
Emitting multiple logs from JSON
Given this Vector log event...
{
  "message": "[{\"message\": \"first_log\"}, {\"message\": \"second_log\"}]"
}
...and this VRL program...
. = parse_json!(.message) # sets `.` to an array of objects
...the following log event is output:
[
  {
    "log": {
      "message": "first_log"
    }
  },
  {
    "log": {
      "message": "second_log"
    }
  }
]
Emitting multiple non-object logs from JSON
Given this Vector log event...
{
  "message": "[5, true, \"hello\"]"
}
...and this VRL program...
. = parse_json!(.message) # sets `.` to an array
...the following log event is output:
[
  {
    "log": {
      "message": 5
    }
  },
  {
    "log": {
      "message": true
    }
  },
  {
    "log": {
      "message": "hello"
    }
  }
]
Invalid argument type
Given this Vector log event...
{
  "not_a_string": 1
}
...and this VRL program...
upcase(42)
...you should see this error:
error[E110]: invalid argument type
  ┌─ :1:8
  │
1 │ upcase(42)
  │        ^^
  │        │
  │        this expression resolves to the exact type integer
  │        but the parameter "value" expects the exact type string
  │
  = try: ensuring an appropriate type at runtime
  =
  =     42 = string!(42)
  =     upcase(42)
  =
  = try: coercing to an appropriate type and specifying a default value as a fallback in case coercion fails
  =
  =     42 = to_string(42) ?? "default"
  =     upcase(42)
  =
  = see documentation about error handling at https://errors.vrl.dev/#handling
  = learn more about error code 110 at https://errors.vrl.dev/110
  = see language documentation at https://vrl.dev
  = try your code in the VRL REPL, learn more at https://vrl.dev/examples
Unhandled fallible assignment
Given this Vector log event...
{
  "message": "key1=value1 key2=value2"
}
...and this VRL program...
structured = parse_key_value(.message)
...you should see this error:
error[E103]: unhandled fallible assignment
  ┌─ :1:14
  │
1 │ structured = parse_key_value(.message)
  │ ------------ ^^^^^^^^^^^^^^^^^^^^^^^^^
  │ │            │
  │ │            this expression is fallible because at least one argument's type cannot be verified to be valid
  │ │            update the expression to be infallible by adding a `!`: `parse_key_value!(.message)`
  │ │            `.message` argument type is `any` and this function expected a parameter `value` of type `string`
  │ or change this to an infallible assignment:
  │ structured, err = parse_key_value(.message)
  │
  = see documentation about error handling at https://errors.vrl.dev/#handling
  = see functions characteristics documentation at https://vrl.dev/expressions/#function-call-characteristics
  = learn more about error code 103 at https://errors.vrl.dev/103
  = see language documentation at https://vrl.dev
  = try your code in the VRL REPL, learn more at https://vrl.dev/examples
On this page

Quickstart
Example: parsing JSON
Example: filtering events
Reference
Learn
The goals of VRL
Concepts
Assertions
Boolean expressions
Event
Characteristics
Paths
Expressions
Function
Characteristics
Deprecation
Fallibility
Literal
Transforming metrics
Program
Features
Compilation
Characteristics
Fail safety checks
Type safety checks
Ergonomic safety
Characteristics
Internal logging limitation
I/O limitation
Lack of custom functions
Purpose built for observability
Rate-limited logging
Lack of recursion
Lack of state
Fail safety
High-quality error messages
Logs and metrics
Memory safety
Vector & Rust native
Characteristics
Lack of garbage collection
Stateless
Type safety
Characteristics
Progressive type safety
Principles
Performance
Safety
Other examples
Parse Syslog logs
Parse key/value (logfmt) logs
Parse custom logs
Multiple parsing strategies
Modify metric tags
Emitting multiple logs from JSON
Emitting multiple non-object logs from JSON
Invalid argument type
Unhandled fallible assignment
Vector site footer
About
Vector
Contact us
The Team
Privacy
Cookies
Components
Sources
Transforms
Sinks
Setup
Installation
Deployment
Configuration
Administration
Going to Prod
Community
GitHub
Twitter
Chat
Download
Releases
Twitter icon and link
GitHub icon and link
Chat icon and link
RSS icon and link
© 2025 Datadog, Inc. All rights reserved.