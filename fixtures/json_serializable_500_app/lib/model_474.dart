import 'package:json_annotation/json_annotation.dart';

part 'model_474.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model474 {
  const Model474({required this.id, required this.value});

  final int id;
  final String value;

  factory Model474.fromJson(Map<String, dynamic> json) =>
      _$Model474FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model474ToJson(this);
}
