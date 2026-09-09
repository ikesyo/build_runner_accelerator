import 'package:json_annotation/json_annotation.dart';

part 'model_413.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model413 {
  const Model413({required this.id, required this.value});

  final int id;
  final String value;

  factory Model413.fromJson(Map<String, dynamic> json) =>
      _$Model413FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model413ToJson(this);
}
