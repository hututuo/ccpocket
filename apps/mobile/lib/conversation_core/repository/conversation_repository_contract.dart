import 'conversation_repository_models.dart';

/// Bytes and digest returned by the generated contract adapter.
///
/// The repository never constructs a canonical JSON value or sorts keys.  It
/// only verifies that the adapter's bytes hash to the adapter's digest while
/// staging and sealing a transaction.  The generated adapter is where the
/// RFC 8785 implementation and the cross-language golden vectors live.
class ContractPreimage {
  ContractPreimage({
    required List<int> bytes,
    required this.digest,
    required this.authorityId,
    required this.authorityProfile,
    this.algorithm = 'SHA256_RFC8785',
  }) : bytes = List<int>.unmodifiable(bytes);

  final List<int> bytes;
  final String digest;
  final String authorityId;

  /// An opaque, library-owned profile token.  The generated contract output
  /// will be emitted as a `part` of this library and receive the private
  /// generated token there.  Keeping the token out of the public API prevents
  /// a caller from self-declaring a fixture or generated authority by string
  /// value alone.
  final Object authorityProfile;
  final String algorithm;
}

// These identities are deliberately object tokens rather than public strings.
// The generated profile has no final value in this checkout; generated output
// must bind to the private token when it is eventually added.  Tests may use
// the fixture token only through ConversationRepository.forTesting.
final Object _generatedAuthorityProfile = Object();
final Object _fixtureAuthorityProfile = Object();
final Object _unavailableAuthorityProfile = Object();

/// Returns whether [profile] is the private generated profile token.  The
/// token itself is never returned by this API; generated output added as a
/// library part can bind it internally, while callers can only ask about a
/// value they already possess.
bool isGeneratedConversationAuthorityProfile(Object profile) =>
    identical(profile, _generatedAuthorityProfile);

/// Test-only profile access for [ConversationRepository.forTesting].  Normal
/// repository construction rejects this token.
Object conversationFixtureAuthorityProfileForTesting() =>
    _fixtureAuthorityProfile;

bool isFixtureConversationAuthorityProfile(Object profile) =>
    identical(profile, _fixtureAuthorityProfile);

/// The one authority seam for all repository digests.
///
/// The formal generated outputs are intentionally absent in this checkout.
/// Production construction therefore uses [UnavailableConversationContract]
/// and fails closed.  A test may inject an explicitly marked fixture adapter
/// to exercise SQLite, lifecycle, and ordering behavior without pretending
/// that a fixture is the final RFC 8785 contract.
abstract interface class ConversationContractMapper {
  const ConversationContractMapper();

  /// Opaque profile binding used by the repository to classify the mapper.
  /// Implementations outside this library can provide the fixture token only
  /// through the explicit test constructor; the generated token is private.
  Object get authorityProfile;

  /// Retained as an informational compatibility getter.  Repository
  /// admission never trusts this caller-controlled boolean; it derives the
  /// mode from [authorityProfile] identity instead.
  bool get isGenerated;

  String get authorityId;

  ContractPreimage begin(MaterializationBegin value);

  ContractPreimage pageBody(MaterializationPageBody value);

  ContractPreimage emptyProof(ReplicaEmptyProof value);

  ContractPreimage item(CanonicalItem value);

  ContractPreimage gap(TypedGap value);

  ContractPreimage envelope(RepositoryEnvelopeInput value);

  ContractPreimage orderProof(RepositoryOrderInput value);

  ContractPreimage pageManifest(Iterable<String> pageDigests);

  ContractPreimage runtimeProjection(RuntimeProjectionEnvelope value);

  ContractPreimage operationProjection(OperationProjection value);

  ContractPreimage queueEntryProjection(QueueEntryProjection value);

  ContractPreimage interactionProjection(InteractionProjection value);
}

/// A contract-neutral description passed to the generated mapper.
class RepositoryEnvelopeInput {
  RepositoryEnvelopeInput({
    required this.envelopeId,
    required this.key,
    required this.fence,
    required this.sourceRevision,
    required this.coverage,
    required this.health,
    required this.problemCode,
    required this.isSnapshot,
    required this.pageCount,
    required this.totalItemCount,
    required this.providerReadEvidenceDigest,
    required this.emptyProof,
    required this.items,
    required this.gaps,
  });

  final String envelopeId;
  final ThreadKey key;
  final EnvelopeFence fence;
  final int sourceRevision;
  final Coverage coverage;
  final ReadHealth health;
  final String? problemCode;
  final bool isSnapshot;
  final int pageCount;
  final int totalItemCount;
  final String providerReadEvidenceDigest;
  final ReplicaEmptyProof? emptyProof;
  final List<CanonicalItem> items;
  final List<TypedGap> gaps;
}

class RepositoryOrderInput {
  RepositoryOrderInput({
    required this.key,
    required this.materializationId,
    required this.items,
    required this.gaps,
  });

  final ThreadKey key;
  final String materializationId;
  final List<CanonicalItem> items;
  final List<TypedGap> gaps;
}

/// Formal generated outputs are not present in this worktree.  This adapter
/// is deliberately not a permissive fallback: every preimage request fails.
class UnavailableConversationContract implements ConversationContractMapper {
  const UnavailableConversationContract();

  @override
  Object get authorityProfile => _unavailableAuthorityProfile;

  @override
  bool get isGenerated => false;

  @override
  String get authorityId => 'generated-contract-unavailable';

  Never _unavailable() {
    throw const ConversationRepositoryException(
      RepositoryFailureCode.contractUnavailable,
      'generated conversation contract outputs are unavailable; repository is fail-closed',
    );
  }

  @override
  ContractPreimage begin(MaterializationBegin value) => _unavailable();

  @override
  ContractPreimage pageBody(MaterializationPageBody value) => _unavailable();

  @override
  ContractPreimage emptyProof(ReplicaEmptyProof value) => _unavailable();

  @override
  ContractPreimage item(CanonicalItem value) => _unavailable();

  @override
  ContractPreimage gap(TypedGap value) => _unavailable();

  @override
  ContractPreimage envelope(RepositoryEnvelopeInput value) => _unavailable();

  @override
  ContractPreimage orderProof(RepositoryOrderInput value) => _unavailable();

  @override
  ContractPreimage pageManifest(Iterable<String> pageDigests) => _unavailable();

  @override
  ContractPreimage runtimeProjection(RuntimeProjectionEnvelope value) =>
      _unavailable();

  @override
  ContractPreimage operationProjection(OperationProjection value) =>
      _unavailable();

  @override
  ContractPreimage queueEntryProjection(QueueEntryProjection value) =>
      _unavailable();

  @override
  ContractPreimage interactionProjection(InteractionProjection value) =>
      _unavailable();
}
