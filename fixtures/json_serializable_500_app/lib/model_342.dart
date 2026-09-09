import 'package:json_annotation/json_annotation.dart';

part 'model_342.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model342 {
  const Model342({required this.id, required this.value});

  final int id;
  final String value;

  factory Model342.fromJson(Map<String, dynamic> json) =>
      _$Model342FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model342ToJson(this);
}
