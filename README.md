# Programming Language

Simple statically typed and compiled programming language implemented in Zig, with support for variables, control flow, functions, and code generation using LLVM.

## Building and Running

1. Ensure you have Zig and LLVM installed on your system.
2. Run the compiler on an example file:
   ```
   zig build run -- examples/8.src compile
   ```
3. Link the generated object file to create an executable:
   ```
   cc output.o
   ```
4. Run the executable:
   ```
   ./a.out
   ```

## Language Features

- **Variables and Declarations**: Uses `let` for variable declaration.
- **Control Flow**: Supports `if` and `while` statements.
- **Functions**: Supports function declarations with parameters and return types.
- **Expressions**: Includes additive, multiplicative, equality, and unary expressions.
- **Code Generation with LLVM**: Translates AST to LLVM IR and generates object files for native execution.

## Example Program

```js
let main = () => i64 {
	let fib = (n: i64) => i64 {
		if n == 0 {
			return 0;
		};
		if n == 1 {
			return 1;
		};
		return fib(n-2) + fib(n-1);
	};

	let result = fib(30);
	print(result);
	return result;
};
```
```
Output: 832040
```
