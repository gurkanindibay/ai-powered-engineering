/// A person reference accepted by person-aware site commands.
///
/// References are either an existing card id or a draft card that the server
/// should resolve and create in the same transaction as the command.
class PersonRef {
  final int? personId;
  final String? fullName;
  final String? phone;
  final String? email;
  final bool confirmDistinct;

  const PersonRef._({
    this.personId,
    this.fullName,
    this.phone,
    this.email,
    this.confirmDistinct = false,
  });

  const PersonRef.existing(int id) : this._(personId: id);

  const PersonRef.draft({
    required String fullName,
    String? phone,
    String? email,
    bool confirmDistinct = false,
  }) : this._(
         fullName: fullName,
         phone: phone,
         email: email,
         confirmDistinct: confirmDistinct,
       );

  factory PersonRef.fromJson(Map<String, dynamic> json) {
    final kind = json['kind'];
    if (kind == 'existing' && json['person_id'] is num) {
      return PersonRef.existing((json['person_id'] as num).toInt());
    }
    final draft = json['card'];
    if (kind == 'new' && draft is Map<String, dynamic>) {
      return PersonRef.draft(
        fullName: draft['full_name']?.toString() ?? '',
        phone: draft['phone']?.toString(),
        email: draft['email']?.toString(),
        confirmDistinct: json['confirm_distinct'] as bool? ?? false,
      );
    }
    throw const FormatException(
      'PersonRef must contain an existing id or a new person.',
    );
  }

  bool get isExisting => personId != null;

  Map<String, Object?> toJson() => isExisting
      ? {'kind': 'existing', 'person_id': personId}
      : {
          'kind': 'new',
          'card': {
            'full_name': fullName,
            if (phone?.trim().isNotEmpty == true) 'phone': phone!.trim(),
            if (email?.trim().isNotEmpty == true) 'email': email!.trim(),
          },
          'confirm_distinct': confirmDistinct,
        };
}

/// A household member chosen during unit registration, with a display copy of the card.
class RegistrationMember {
  final PersonRef person;
  final String relationship;
  final String fullName;
  final String phone;
  final String email;

  const RegistrationMember({
    required this.person,
    required this.relationship,
    this.fullName = '',
    this.phone = '',
    this.email = '',
  });
}
