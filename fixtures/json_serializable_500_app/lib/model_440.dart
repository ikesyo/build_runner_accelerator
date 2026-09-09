import 'package:json_annotation/json_annotation.dart';

part 'model_440.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model440 {
  const Model440({required this.id, required this.value});

  final int id;
  final String value;

  factory Model440.fromJson(Map<String, dynamic> json) =>
      _$Model440FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model440ToJson(this);
}
