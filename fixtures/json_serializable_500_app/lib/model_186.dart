import 'package:json_annotation/json_annotation.dart';

part 'model_186.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model186 {
  const Model186({required this.id, required this.value});

  final int id;
  final String value;

  factory Model186.fromJson(Map<String, dynamic> json) =>
      _$Model186FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model186ToJson(this);
}
