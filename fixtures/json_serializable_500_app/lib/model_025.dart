import 'package:json_annotation/json_annotation.dart';

part 'model_025.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model025 {
  const Model025({required this.id, required this.value});

  final int id;
  final String value;

  factory Model025.fromJson(Map<String, dynamic> json) =>
      _$Model025FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model025ToJson(this);
}
