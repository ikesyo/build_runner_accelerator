import 'package:json_annotation/json_annotation.dart';

part 'model_100.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model100 {
  const Model100({required this.id, required this.value});

  final int id;
  final String value;

  factory Model100.fromJson(Map<String, dynamic> json) =>
      _$Model100FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model100ToJson(this);
}
