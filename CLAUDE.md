## About
This codebase is a protocol that enables lending secured by position tokens in prediction markets. It has a two-layer structure that wraps Aave as the
liquidity layer and enables borrowing using position tokens.

# design concept
The implementation policy is as follows.
1. PureDriven:
The protocol behavior is determined entirely by a Core library consisting solely of pure functions. Understanding the Core's input/output will enable you to understand all of the protocol's behavior in specific situations.
2. Priority use of audited libraries
Prioritize the use of numerical calculation libraries such as aave and oz to enhance numerical calculation safety.
3. Library division
Divide libraries into separate modules based on specific concerns.


**Please check the codebase carefully, think as much as possible, and write efficient and safe code.**