import 'package:json_annotation/json_annotation.dart';

part 'model_277.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model277 {
  const Model277({required this.id, required this.value});

  final int id;
  final String value;

  factory Model277.fromJson(Map<String, dynamic> json) =>
      _$Model277FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model277ToJson(this);
}
