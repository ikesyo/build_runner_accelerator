import 'package:json_annotation/json_annotation.dart';

part 'model_107.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model107 {
  const Model107({required this.id, required this.value});

  final int id;
  final String value;

  factory Model107.fromJson(Map<String, dynamic> json) =>
      _$Model107FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model107ToJson(this);
}
