import 'package:json_annotation/json_annotation.dart';

part 'model_332.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model332 {
  const Model332({required this.id, required this.value});

  final int id;
  final String value;

  factory Model332.fromJson(Map<String, dynamic> json) =>
      _$Model332FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model332ToJson(this);
}
