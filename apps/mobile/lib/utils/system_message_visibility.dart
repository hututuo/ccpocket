import '../models/messages.dart';

/// System messages still update runtime metadata even when they are not
/// useful transcript content. Keep only the session boundary and actionable
/// tips visible; model/effort/speed/capability acknowledgements belong to the
/// toolbar and would otherwise be replayed as repeated `System:` chips.
bool shouldDisplaySystemMessage(SystemMessage message) =>
    message.subtype == 'init' || message.subtype == 'tip';
