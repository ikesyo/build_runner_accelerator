import 'package:json_annotation/json_annotation.dart';

part 'model_417.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model417 {
  const Model417({required this.id, required this.value});

  final int id;
  final String value;

  factory Model417.fromJson(Map<String, dynamic> json) =>
      _$Model417FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model417ToJson(this);
}
