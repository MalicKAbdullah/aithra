/// Saving a user's message to long-term memory because they asked to
/// ("Remember this"), bypassing the curator's judgement of what is worth
/// keeping. Implemented by the memory service, which decides where in the
/// profile the fact belongs.
abstract interface class ExplicitMemory {
  Future<void> rememberExplicit(String text);
}
