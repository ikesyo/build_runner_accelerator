import 'package:json_annotation/json_annotation.dart';

part 'model_434.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model434 {
  const Model434({required this.id, required this.value});

  final int id;
  final String value;

  factory Model434.fromJson(Map<String, dynamic> json) =>
      _$Model434FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model434ToJson(this);
}
