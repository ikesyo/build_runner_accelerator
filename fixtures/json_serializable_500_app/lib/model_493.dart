import 'package:json_annotation/json_annotation.dart';

part 'model_493.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model493 {
  const Model493({required this.id, required this.value});

  final int id;
  final String value;

  factory Model493.fromJson(Map<String, dynamic> json) =>
      _$Model493FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model493ToJson(this);
}
