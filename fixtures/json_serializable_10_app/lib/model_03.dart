import 'package:json_annotation/json_annotation.dart';

part 'model_03.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model03 {
  const Model03({required this.id, required this.value});

  final int id;
  final String value;

  factory Model03.fromJson(Map<String, dynamic> json) =>
      _$Model03FromJson(json);

  Map<String, dynamic> toJson() => _$Model03ToJson(this);
}
